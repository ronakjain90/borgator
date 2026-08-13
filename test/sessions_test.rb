# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'time'
require_relative '../lib/borgator/sessions'

# Conversations are saved per project and per wire format, so /resume can only
# ever offer a session the current provider is able to replay.
class SessionsTest < Minitest::Test
  class FakeProvider
    def initialize(label = 'anthropic', model = 'claude-opus-4-8', shape = :anthropic)
      @label = label
      @model = model
      @shape = shape
    end

    attr_reader :label

    def model_label = @model
    def message_shape = @shape
  end

  def setup
    @home = Dir.mktmpdir
    @project = Dir.mktmpdir
    ENV['BORGATOR_SESSIONS_DIR'] = @home
  end

  def teardown
    ENV.delete('BORGATOR_SESSIONS_DIR')
    FileUtils.remove_entry(@home)
    FileUtils.remove_entry(@project)
  end

  def messages(*prompts)
    prompts.flat_map do |prompt|
      [{ 'role' => 'user', 'content' => prompt }, { 'role' => 'assistant', 'content' => 'ok' }]
    end
  end

  def save(id, prompts: ['fix the drain buffer'], provider: FakeProvider.new, log: [], root: @project)
    Sessions.save(id: id, provider: provider, messages: messages(*prompts), log: log, root: root)
  end

  def test_round_trip_keeps_messages_and_metadata
    save('s1', prompts: ['fix the drain buffer'],
               log: [{ kind: :user, text: 'fix the drain buffer', depth: 0 },
                     { kind: :assistant, text: 'done', depth: 0 }])

    session = Sessions.load('s1', root: @project)
    assert_equal 'fix the drain buffer', session[:title]
    assert_equal 'anthropic', session[:shape]
    assert_equal 'claude-opus-4-8', session[:model]
    assert_equal 2, session[:messages].length
    assert_equal(%i[user assistant], session[:log].map { |e| e[:kind] })
  end

  def test_recent_lists_newest_first_with_turn_counts
    save('s1', prompts: ['first thing'])
    sleep 0.01
    save('s2', prompts: ['second thing', 'and more'])

    entries = Sessions.recent(root: @project)
    assert_equal(%w[s2 s1], entries.map { |e| e[:id] })
    assert_equal 2, entries.first[:turns]
    assert_equal 'second thing', entries.first[:title]
  end

  def test_recent_filters_to_a_matching_wire_format
    save('anthropic-one')
    save('openai-one', provider: FakeProvider.new('openai', 'gpt-4o', :openai))

    assert_equal(['anthropic-one'], Sessions.recent(shape: 'anthropic', root: @project).map { |e| e[:id] })
    assert_equal(['openai-one'], Sessions.recent(shape: :openai, root: @project).map { |e| e[:id] })
  end

  def test_sessions_are_scoped_to_their_project
    other = Dir.mktmpdir
    save('here')
    save('elsewhere', root: other)

    assert_equal(['here'], Sessions.recent(root: @project).map { |e| e[:id] })
    assert_equal(['elsewhere'], Sessions.recent(root: other).map { |e| e[:id] })
  ensure
    FileUtils.remove_entry(other)
  end

  # Two checkouts sharing a basename must not share a history.
  def test_same_basename_different_path_are_separate
    a = File.join(@project, 'a', 'borgator')
    b = File.join(@project, 'b', 'borgator')
    refute_equal Sessions.project_dir(a), Sessions.project_dir(b)
  end

  def test_re_saving_updates_in_place_and_keeps_creation_time
    save('s1', prompts: ['first thing'])
    created = JSON.parse(File.read(Sessions.path_for('s1', @project)))['created_at']
    sleep 0.01
    save('s1', prompts: ['first thing', 'second'])

    assert_equal 1, Sessions.recent(root: @project).length
    data = JSON.parse(File.read(Sessions.path_for('s1', @project)))
    assert_equal created, data['created_at']
    assert_operator data['updated_at'], :>=, created
  end

  def test_oldest_sessions_are_pruned
    (Sessions::MAX_PER_PROJECT + 5).times { |i| save(format('s%03d', i)) }

    entries = Sessions.recent(root: @project, limit: 100)
    assert_equal Sessions::MAX_PER_PROJECT, entries.length
    refute_includes entries.map { |e| e[:id] }, 's000'
  end

  def test_transient_log_kinds_are_dropped_and_long_text_capped
    save('s1', log: [{ kind: :user, text: 'x', depth: 0 },
                     { kind: :permission_request, text: 'rm -rf', depth: 0 },
                     { kind: :tool_result, text: 'y' * (Sessions::MAX_LOG_TEXT + 50), depth: 1 }])

    log = Sessions.load('s1', root: @project)[:log]
    assert_equal(%i[user tool_result], log.map { |e| e[:kind] })
    assert_equal Sessions::MAX_LOG_TEXT + 1, log.last[:text].length
    assert_equal 1, log.last[:depth]
  end

  def test_empty_conversations_are_not_saved
    assert_nil Sessions.save(id: 's1', provider: FakeProvider.new, messages: [], log: [], root: @project)
    assert_empty Sessions.recent(root: @project)
  end

  def test_unreadable_and_foreign_files_are_ignored
    save('good')
    dir = Sessions.project_dir(@project)
    File.write(File.join(dir, 'broken.json'), '{not json')
    File.write(File.join(dir, 'future.json'), JSON.generate('format' => 99, 'id' => 'future'))

    assert_equal(['good'], Sessions.recent(root: @project).map { |e| e[:id] })
    assert_nil Sessions.load('future', root: @project)
  end

  def test_title_skips_non_text_messages
    msgs = [{ 'role' => 'user', 'content' => [{ 'type' => 'tool_result', 'content' => 'ok' }] },
            { 'role' => 'user', 'content' => "  \nactual question\nmore" }]
    Sessions.save(id: 's1', provider: FakeProvider.new, messages: msgs, log: [], root: @project)

    assert_equal 'actual question', Sessions.load('s1', root: @project)[:title]
  end

  def test_shape_of_ignores_providers_that_do_not_declare_one
    assert_equal 'anthropic', Sessions.shape_of(FakeProvider.new)
    assert_nil Sessions.shape_of(Object.new)
  end

  def test_age_reads_as_relative_time
    assert_equal 'just now', Sessions.age(Time.now - 5)
    assert_equal '5m ago', Sessions.age(Time.now - 300)
    assert_equal '3h ago', Sessions.age(Time.now - (3 * 3600))
    assert_equal '2d ago', Sessions.age(Time.now - (2 * 86_400))
  end
end
