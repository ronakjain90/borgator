# frozen_string_literal: true

require_relative 'tools/helper'
require_relative '../lib/borgator/checkpoints'
require_relative '../lib/borgator/tools/write_file'
require_relative '../lib/borgator/tools/edit_file'

# /undo: file changes made by a turn are snapshotted and rewindable.
class CheckpointsTest < Minitest::Test
  include ToolTestHelper

  def setup
    Checkpoints.reset!
  end

  def teardown
    Checkpoints.reset!
  end

  def test_undo_restores_an_edited_file
    in_project do
      File.write('a.rb', "one\ntwo\n")
      Checkpoints.begin_turn('rename two')
      Tools::EditFile.call('path' => 'a.rb', 'old_string' => 'two', 'new_string' => 'TWO')
      assert_equal "one\nTWO\n", File.read('a.rb')

      result = Checkpoints.undo
      assert_equal 'rename two', result[:label]
      assert_equal ['a.rb'], result[:restored]
      assert_empty result[:skipped]
      assert_equal "one\ntwo\n", File.read('a.rb')
    end
  end

  def test_undo_deletes_a_file_the_turn_created
    in_project do
      Checkpoints.begin_turn('add a file')
      Tools::WriteFile.call('path' => 'new.rb', 'content' => "hi\n")

      result = Checkpoints.undo
      assert_equal ['new.rb'], result[:deleted]
      refute File.exist?('new.rb')
    end
  end

  def test_undo_rewinds_only_the_last_turn
    in_project do
      File.write('a.rb', "v0\n")

      Checkpoints.begin_turn('first')
      Tools::WriteFile.call('path' => 'a.rb', 'content' => "v1\n")
      Checkpoints.begin_turn('second')
      Tools::WriteFile.call('path' => 'a.rb', 'content' => "v2\n")

      assert_equal 'second', Checkpoints.undo[:label]
      assert_equal "v1\n", File.read('a.rb')

      assert_equal 'first', Checkpoints.undo[:label]
      assert_equal "v0\n", File.read('a.rb')

      assert_nil Checkpoints.undo
    end
  end

  # The first snapshot within a turn wins: undo rewinds to the turn's start, not
  # to the state between two edits the same turn made.
  def test_repeated_edits_in_one_turn_rewind_to_the_turn_start
    in_project do
      File.write('a.rb', "start\n")
      Checkpoints.begin_turn('two edits')
      Tools::WriteFile.call('path' => 'a.rb', 'content' => "middle\n")
      Tools::WriteFile.call('path' => 'a.rb', 'content' => "end\n")

      Checkpoints.undo
      assert_equal "start\n", File.read('a.rb')
    end
  end

  def test_file_changed_after_the_agent_wrote_it_is_kept
    in_project do
      File.write('a.rb', "original\n")
      Checkpoints.begin_turn('edit')
      Tools::WriteFile.call('path' => 'a.rb', 'content' => "agent\n")
      File.write('a.rb', "hand edited\n")

      result = Checkpoints.undo
      assert_empty result[:restored]
      assert_equal 'a.rb', result[:skipped].first[:path]
      assert_match(/changed after/, result[:skipped].first[:reason])
      assert_equal "hand edited\n", File.read('a.rb')
    end
  end

  def test_deleted_file_is_reported_not_recreated
    in_project do
      File.write('a.rb', "original\n")
      Checkpoints.begin_turn('edit')
      Tools::WriteFile.call('path' => 'a.rb', 'content' => "agent\n")
      File.delete('a.rb')

      result = Checkpoints.undo
      assert_match(/no longer exists/, result[:skipped].first[:reason])
      refute File.exist?('a.rb')
    end
  end

  def test_turns_without_file_changes_are_skipped
    in_project do
      File.write('a.rb', "v0\n")
      Checkpoints.begin_turn('writes something')
      Tools::WriteFile.call('path' => 'a.rb', 'content' => "v1\n")
      Checkpoints.begin_turn('just a question')

      assert_equal 'writes something', Checkpoints.pending_label
      assert_equal 1, Checkpoints.pending_count
      assert_equal 'writes something', Checkpoints.undo[:label]
      assert_equal "v0\n", File.read('a.rb')
    end
  end

  def test_writes_without_an_open_turn_are_still_recorded
    in_project do
      Tools::WriteFile.call('path' => 'stray.rb', 'content' => "x\n")

      result = Checkpoints.undo
      refute_nil result
      assert_equal ['stray.rb'], result[:deleted]
    end
  end

  def test_oldest_turns_fall_out_of_the_window
    in_project do
      (Checkpoints::MAX_TURNS + 3).times do |i|
        Checkpoints.begin_turn("turn #{i}")
        Tools::WriteFile.call('path' => "f#{i}.rb", 'content' => "#{i}\n")
      end

      labels = []
      while (result = Checkpoints.undo)
        labels << result[:label]
      end
      assert_equal Checkpoints::MAX_TURNS, labels.length
      assert_equal "turn #{Checkpoints::MAX_TURNS + 2}", labels.first
    end
  end

  def test_nothing_to_undo_returns_nil
    in_project do
      assert_nil Checkpoints.undo
      Checkpoints.begin_turn('no writes here')
      assert_nil Checkpoints.undo
      assert_nil Checkpoints.pending_label
    end
  end

  def test_concurrent_writes_in_one_turn_are_all_recorded
    in_project do
      Checkpoints.begin_turn('parallel writes')
      threads = 8.times.map do |i|
        Thread.new { Tools::WriteFile.call('path' => "p#{i}.rb", 'content' => "#{i}\n") }
      end
      threads.each(&:join)

      result = Checkpoints.undo
      assert_equal 8, result[:deleted].length
      assert_empty Dir.glob('p*.rb')
    end
  end
end
