# frozen_string_literal: true

require 'digest'

# Rewindable snapshots of the files the agent changes.
#
# Every `write_file` / `edit_file` stores the file's prior contents in the
# *current turn* as the change lands. `/undo` rewinds the newest turn that
# touched files, so a bad turn costs one command instead of manual git surgery.
#
# Snapshots are per-session and in memory only. Restoring a snapshot taken by an
# earlier session could clobber newer work, so they intentionally do not survive
# a quit. Only the in-process file tools are covered — files written by
# `run_command` are invisible here and are never restored.
#
# A file is only rewound when it still holds exactly what the agent wrote
# (tracked by digest); anything edited afterwards — by the user, by a formatter,
# by a later shell command — is reported as skipped rather than overwritten.
module Checkpoints
  # Turns retained; older ones fall out of the window.
  MAX_TURNS = 20

  # Files bigger than this are noted but not snapshotted, so one huge write
  # can't pin the whole session's memory.
  MAX_FILE_BYTES = 4_000_000

  # Total snapshot bytes retained across all turns.
  MAX_TOTAL_BYTES = 64_000_000

  MAX_LABEL_CHARS = 60

  DEFAULT_LABEL = 'file changes'

  class << self
    # Open a checkpoint for the turn about to run. Tool writes during the turn
    # accumulate into it; the label is what `/undo` reports rewinding.
    def begin_turn(label)
      sync { open_turn(label) }
    end

    # Snapshot one file change. Called by the file tools while they hold the
    # path's lock, so `before` is the content the change actually replaced.
    #
    # @param path [String] path as the tool received it (used for display)
    # @param before [String, nil] prior contents; nil when the file was created
    # @param after [String] contents just written, to detect later edits
    def record(path, before:, after:)
      sync do
        open_turn(DEFAULT_LABEL) if @turns.empty?
        entry = @turns.last[:files][File.expand_path(path)]
        if entry
          # First snapshot of a path within a turn wins — it holds the state the
          # turn started from — but the digest must track the newest write.
          entry[:after_digest] = digest(after)
        else
          @turns.last[:files][File.expand_path(path)] = new_entry(path, before, after)
        end
        trim!
      end
    end

    # Label of the turn `/undo` would rewind, or nil when there is nothing.
    def pending_label
      sync { newest_undoable&.fetch(:label) }
    end

    # Number of files the next `/undo` would touch.
    def pending_count
      sync { newest_undoable&.fetch(:files)&.size.to_i }
    end

    # Rewind the newest turn that changed files.
    #
    # @return [Hash, nil] +nil+ when nothing is recorded, otherwise
    #   +{ label:, restored: [], deleted: [], skipped: [{ path:, reason: }] }+
    def undo
      turn = sync do
        drop_empty_turns
        @turns.pop
      end
      return nil unless turn

      rewind(turn)
    end

    def reset!
      sync { @turns = [] }
    end

    private

    def sync(&)
      @mutex ||= Mutex.new
      @turns ||= []
      @mutex.synchronize(&)
    end

    # Caller holds the lock.
    def open_turn(label)
      # Drop a trailing turn that changed nothing so quiet turns can't push real
      # checkpoints out of the window.
      @turns.pop if @turns.last && @turns.last[:files].empty?
      @turns << { label: summarize(label), files: {} }
      trim!
    end

    def new_entry(path, before, after)
      oversize = !before.nil? && before.bytesize > MAX_FILE_BYTES
      {
        display: path.to_s,
        existed: !before.nil?,
        oversize: oversize,
        before: oversize ? nil : before,
        bytes: oversize ? 0 : before.to_s.bytesize,
        after_digest: digest(after)
      }
    end

    def drop_empty_turns
      @turns.pop while @turns.last && @turns.last[:files].empty?
    end

    def newest_undoable
      @turns.reverse.find { |turn| turn[:files].any? }
    end

    def summarize(label)
      text = label.to_s.strip.split("\n").first.to_s.strip
      return DEFAULT_LABEL if text.empty?
      return text if text.length <= MAX_LABEL_CHARS

      "#{text[0, MAX_LABEL_CHARS - 1]}…"
    end

    def digest(content)
      Digest::SHA256.hexdigest(content.to_s)
    end

    # Oldest-first eviction, by turn count and then by retained bytes.
    def trim!
      @turns.shift while @turns.length > MAX_TURNS

      total = @turns.sum { |turn| turn[:files].sum { |_path, entry| entry[:bytes] } }
      while total > MAX_TOTAL_BYTES && @turns.length > 1
        dropped = @turns.shift
        total -= dropped[:files].sum { |_path, entry| entry[:bytes] }
      end
    end

    def rewind(turn)
      result = { label: turn[:label], restored: [], deleted: [], skipped: [] }

      turn[:files].each do |abs, entry|
        outcome, reason = restore_file(abs, entry)
        case outcome
        when :restored then result[:restored] << entry[:display]
        when :deleted  then result[:deleted] << entry[:display]
        else result[:skipped] << { path: entry[:display], reason: reason }
        end
      end

      result
    end

    # @return [Array(Symbol, String, nil)] +[:restored | :deleted | :skipped, reason]+
    def restore_file(abs, entry)
      return [:skipped, "snapshot too large (over #{MAX_FILE_BYTES} bytes)"] if entry[:oversize]

      if (reason = stale_reason(abs, entry))
        return [:skipped, reason]
      end

      if entry[:existed]
        File.write(abs, entry[:before])
        [:restored, nil]
      else
        File.delete(abs)
        [:deleted, nil]
      end
    rescue SystemCallError, IOError => e
      [:skipped, e.message]
    end

    # Why this file must not be rewound, or nil when it still holds exactly what
    # the agent wrote.
    def stale_reason(abs, entry)
      return entry[:existed] ? 'no longer exists' : 'already removed' unless File.file?(abs)

      return nil if digest(File.read(abs)) == entry[:after_digest]

      'changed after the agent wrote it'
    end
  end
end
