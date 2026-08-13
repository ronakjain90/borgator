# frozen_string_literal: true

require_relative '../checkpoints'

module Commands
  # The /undo command: rewind the file changes made by the most recent turn.
  # Mixed into AgentApp, so it works on the app's state (@log, @thinking,
  # @pending_notes) like the other commands.
  #
  # Snapshots come from {Checkpoints}, which the file tools populate as they
  # write. A file is only rewound while it still holds exactly what the agent
  # wrote — anything touched since is reported and left alone.
  module Undo
    def handle_undo
      if @thinking
        @log << { kind: :error, text: 'a turn is running — press esc to interrupt it first' }
        return [self, nil]
      end

      result = Checkpoints.undo
      if result.nil?
        @log << { kind: :assistant, text: 'Nothing to undo — no agent file changes recorded this session.' }
        return [self, nil]
      end

      log_undo(result)
      queue_undo_note(result)
      [self, nil]
    end

    private

    def log_undo(result)
      rewound = result[:restored].length + result[:deleted].length
      @log << { kind: :assistant,
                text: "Undid \"#{result[:label]}\" — #{rewound} file#{'s' if rewound != 1} rewound" }
      result[:restored].each { |path| @log << { kind: :tool_result, text: "  restored #{path}" } }
      result[:deleted].each { |path| @log << { kind: :tool_result, text: "  removed #{path} (that turn created it)" } }
      result[:skipped].each do |skip|
        @log << { kind: :error, text: "kept #{skip[:path]} — #{skip[:reason]}" }
      end
    end

    # Tell the model on the next turn, so it stops reasoning from state that is
    # no longer on disk. Queued rather than appended as its own message:
    # providers that require strictly alternating roles reject two user
    # messages in a row.
    def queue_undo_note(result)
      rewound = result[:restored] + result[:deleted]
      return if rewound.empty?

      @pending_notes << '[borgator] The user ran /undo, rolling back the file changes from ' \
                        "\"#{result[:label]}\": #{rewound.join(', ')}. Those files are back to their " \
                        'earlier contents on disk — re-read any of them before editing again.'
    end

    # The user's prompt with any queued session notes in front, so the model
    # learns about out-of-band changes without an extra user message.
    def prompt_with_notes(text)
      return text if @pending_notes.empty?

      notes = @pending_notes.join("\n")
      @pending_notes = []
      "#{notes}\n\n#{text}"
    end
  end
end
