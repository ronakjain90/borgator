# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/borgator'

# /resume: conversations are saved as turns complete and can be reopened,
# but only into a provider that speaks the same wire format.
class ResumeCommandTest < Minitest::Test
  class FakeProvider
    def initialize(label = 'anthropic', model = 'claude-opus-4-8', shape = :anthropic)
      @label = label
      @model = model
      @shape = shape
    end

    attr_reader :label

    def model_label = @model
    def message_shape = @shape
    def run_turn(_messages, events) = events << { kind: :done }
  end

  def setup
    @home = Dir.mktmpdir
    @project = Dir.mktmpdir
    ENV['BORGATOR_SESSIONS_DIR'] = @home
    Sandbox.instance_variable_set(:@root, File.realpath(@project))
    @app = AgentApp.new(FakeProvider.new)
  end

  def teardown
    ENV.delete('BORGATOR_SESSIONS_DIR')
    Sandbox.instance_variable_set(:@root, nil)
    FileUtils.remove_entry(@home)
    FileUtils.remove_entry(@project)
  end

  def log_text
    @app.instance_variable_get(:@log).map { |e| e[:text].to_s }.join("\n")
  end

  def run_prompt(text)
    @app.instance_variable_set(:@input, text)
    @app.send(:submit)
    @app.instance_variable_get(:@worker_thread)&.join
    @app.send(:drain_events)
  end

  def seed_session(id, prompt, provider: FakeProvider.new)
    Sessions.save(id: id, provider: provider,
                  messages: [{ 'role' => 'user', 'content' => prompt },
                             { 'role' => 'assistant', 'content' => 'done' }],
                  log: [{ kind: :user, text: prompt, depth: 0 },
                        { kind: :assistant, text: 'done', depth: 0 }])
  end

  def test_resume_is_a_registered_command
    assert(Commands::ALL.any? { |cmd| cmd[:name] == '/resume' })
  end

  def test_a_completed_turn_is_saved
    run_prompt('fix the drain buffer')

    entries = Sessions.recent
    assert_equal 1, entries.length
    assert_equal 'fix the drain buffer', entries.first[:title]
    assert_equal 'anthropic', entries.first[:shape]
  end

  def test_interrupting_a_turn_still_saves_it
    @app.instance_variable_set(:@input, 'a long one')
    @app.send(:submit)
    @app.instance_variable_get(:@worker_thread)&.join
    @app.send(:interrupt_agent)

    assert_equal(['a long one'], Sessions.recent.map { |e| e[:title] })
  end

  def test_resume_picker_lists_saved_sessions
    seed_session('s1', 'earlier work')
    Commands.run('/resume', @app)

    assert_equal :resume_picker, @app.instance_variable_get(:@mode)
    assert_match(/earlier work/, @app.send(:view_resume_picker))
  end

  def test_resume_restores_messages_and_log
    seed_session('s1', 'earlier work')
    Commands.run('/resume', @app)
    @app.send(:confirm_resume_selection)

    assert_equal :chat, @app.instance_variable_get(:@mode)
    assert_equal 's1', @app.instance_variable_get(:@session_id)
    assert_equal(['earlier work', 'done'],
                 @app.instance_variable_get(:@messages).map { |m| m['content'] })
    assert_match(/Resumed "earlier work" — 1 turn restored/, log_text)
  end

  # Continuing a resumed conversation must write back to the same session,
  # not fork a second copy of it.
  def test_continuing_a_resumed_session_updates_it_in_place
    seed_session('s1', 'earlier work')
    Commands.run('/resume', @app)
    @app.send(:confirm_resume_selection)
    run_prompt('now the next bit')

    entries = Sessions.recent
    assert_equal(['s1'], entries.map { |e| e[:id] })
    assert_equal 2, entries.first[:turns]
  end

  def test_sessions_in_another_wire_format_are_not_offered
    seed_session('openai-one', 'from another provider',
                 provider: FakeProvider.new('openai', 'gpt-4o', :openai))
    Commands.run('/resume', @app)

    assert_equal :chat, @app.instance_variable_get(:@mode)
    assert_match(/No saved conversations/, log_text)
  end

  def test_provider_owning_its_own_history_says_so
    @app.instance_variable_set(:@provider, FakeProvider.new('opencode', 'x/y', :opencode))
    Commands.run('/resume', @app)

    assert_match(/manages its own conversation history/, log_text)
  end

  def test_the_live_session_is_not_offered_to_itself
    run_prompt('the current conversation')
    Commands.run('/resume', @app)

    assert_equal :chat, @app.instance_variable_get(:@mode)
    assert_match(/No saved conversations/, log_text)
  end

  def test_switching_providers_starts_a_new_session_file
    run_prompt('first conversation')
    first_id = @app.instance_variable_get(:@session_id)
    # What the provider/model-set switches do: clear the conversation, rotate
    # the id so the next turn opens its own file.
    @app.instance_variable_set(:@messages, [])
    @app.send(:reset_session!)
    run_prompt('second conversation')

    refute_equal first_id, @app.instance_variable_get(:@session_id)
    assert_equal(['second conversation', 'first conversation'], Sessions.recent.map { |e| e[:title] })
  end
end
