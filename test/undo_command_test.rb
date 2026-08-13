# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/borgator'

# /undo drives Checkpoints from the TUI: it reports what it rewound, refuses to
# run mid-turn, and tells the model about the rollback on the next prompt.
class UndoCommandTest < Minitest::Test
  def setup
    Checkpoints.reset!
    @app = AgentApp.new
  end

  def teardown
    Checkpoints.reset!
    Sandbox.instance_variable_set(:@root, nil)
  end

  def in_project
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        Sandbox.instance_variable_set(:@root, File.realpath(dir))
        yield dir
      end
    end
  end

  def log_text
    @app.instance_variable_get(:@log).map { |e| e[:text].to_s }.join("\n")
  end

  def test_undo_is_a_registered_command
    assert(Commands::ALL.any? { |cmd| cmd[:name] == '/undo' })
    assert_equal ['/undo'], Commands.matching('/un').map { |cmd| cmd[:name] }.sort
  end

  def test_undo_reports_the_rewound_files
    in_project do
      File.write('a.rb', "before\n")
      Checkpoints.begin_turn('tidy a.rb')
      Tools.call('write_file', 'path' => 'a.rb', 'content' => "after\n")
      Tools.call('write_file', 'path' => 'b.rb', 'content' => "new\n")

      Commands.run('/undo', @app)

      assert_match(/Undid "tidy a\.rb" — 2 files rewound/, log_text)
      assert_match(/restored a\.rb/, log_text)
      assert_match(/removed b\.rb/, log_text)
      assert_equal "before\n", File.read('a.rb')
      refute File.exist?('b.rb')
    end
  end

  def test_undo_with_nothing_recorded_says_so
    in_project do
      Commands.run('/undo', @app)
      assert_match(/Nothing to undo/, log_text)
    end
  end

  def test_undo_refuses_while_a_turn_is_running
    in_project do
      File.write('a.rb', "before\n")
      Checkpoints.begin_turn('a turn')
      Tools.call('write_file', 'path' => 'a.rb', 'content' => "after\n")

      @app.instance_variable_set(:@thinking, true)
      Commands.run('/undo', @app)

      assert_match(/a turn is running/, log_text)
      assert_equal "after\n", File.read('a.rb'), 'must not rewind under a live turn'
    end
  end

  # The model must learn the files moved under it, but only as part of the next
  # user prompt — a second user message in a row is rejected by some providers.
  def test_rollback_is_announced_on_the_next_prompt
    in_project do
      File.write('a.rb', "before\n")
      Checkpoints.begin_turn('tidy a.rb')
      Tools.call('write_file', 'path' => 'a.rb', 'content' => "after\n")
      Commands.run('/undo', @app)

      prompt = @app.send(:prompt_with_notes, 'now try again')
      assert_match(%r{ran /undo}, prompt)
      assert_match(/a\.rb/, prompt)
      assert prompt.end_with?('now try again')

      # Consumed: the note rides along once, not on every later prompt.
      assert_equal 'and again', @app.send(:prompt_with_notes, 'and again')
    end
  end

  # Minimal stand-in for a runnable provider: submit only needs a turn to hand
  # the messages to.
  class FakeProvider
    def label = 'fake'
    def model_label = 'fake-1'
    def run_turn(_messages, events) = events << { kind: :done }
  end

  def test_submitting_a_prompt_opens_a_checkpoint_labelled_with_it
    in_project do
      @app.instance_variable_set(:@provider, FakeProvider.new)
      @app.instance_variable_set(:@input, 'add a retry helper')
      @app.send(:submit)
      @app.instance_variable_get(:@worker_thread)&.join

      Tools.call('write_file', 'path' => 'retry.rb', 'content' => "x\n")
      assert_equal 'add a retry helper', Checkpoints.pending_label
      assert_equal 1, Checkpoints.pending_count
    end
  end

  def test_no_note_when_nothing_was_actually_rewound
    in_project do
      File.write('a.rb', "before\n")
      Checkpoints.begin_turn('tidy a.rb')
      Tools.call('write_file', 'path' => 'a.rb', 'content' => "after\n")
      File.write('a.rb', "hand edited\n")

      Commands.run('/undo', @app)

      assert_match(/kept a\.rb/, log_text)
      assert_equal 'just this', @app.send(:prompt_with_notes, 'just this')
    end
  end
end
