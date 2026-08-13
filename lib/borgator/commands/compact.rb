# frozen_string_literal: true

module Commands
  # The /compact command: replace the conversation with a summary of it, so a
  # long session can keep going instead of hitting the context window.
  #
  # The loop already replaces stale tool results with placeholders as the
  # budget fills (Agents.compact_messages), but the conversation itself only
  # grows. This runs one toolless model turn over the history, then seeds a
  # fresh conversation with its summary. Files on disk are untouched — only the
  # model's memory of how they got that way is condensed.
  module Compact
    # Fraction of the context window past which the user is nudged to compact.
    HINT_AT = 0.8

    SUMMARY_SYSTEM = <<~TXT
      You are compacting a coding session's conversation so it can continue in a fresh
      context. Write a handover for yourself: everything you would need to pick this
      work up with no memory of the conversation, and nothing you wouldn't.

      Cover, in this order, skipping anything that doesn't apply:
      - The user's goal, in their terms, including constraints they stated.
      - What has been done so far, with the exact file paths touched and what changed.
      - What was learned about the codebase that was hard to find: where things live,
        conventions, gotchas. Be specific — paths, names, commands that worked.
      - Decisions made and the reasons, including approaches tried and rejected.
      - What is verified (tests run and their result) versus assumed.
      - What is left to do, and the immediate next step.

      Write it as plain prose and lists, addressed to yourself. Do not summarize the
      conversation turn by turn, do not describe what the user "asked" at each step,
      and do not pad it. Facts over narrative. Include no preamble.
    TXT

    def handle_compact(arg = nil)
      return [self, nil] if compaction_blocked?

      focus = arg.to_s.strip
      @log << { kind: :assistant, text: 'Compacting the conversation…' }
      start_thinking!
      @pending_compact = true
      @compact_assistant_text = nil

      messages = @messages.dup << { 'role' => 'user', 'content' => summary_request(focus) }
      @worker_thread = Thread.new(messages, @events) do |msgs, events|
        @provider.agent_run(msgs, events, system: SUMMARY_SYSTEM, tools: [], depth: 0)
      ensure
        events << { kind: :done }
      end

      [self, tick]
    end

    # Nudge once per crossing when the context is filling up. Called at the end
    # of a turn, where the user can act on it.
    def maybe_hint_compaction
      filled = context_window.positive? ? display_context_tokens.to_f / context_window : 0.0
      if filled < HINT_AT
        @compact_hinted = false
        return
      end
      return if @compact_hinted || @pending_compact

      @compact_hinted = true
      @log << { kind: :assistant,
                text: "Context is #{(filled * 100).round}% full — /compact summarizes the " \
                      'conversation so this session can keep going.' }
    end

    private

    def compaction_blocked?
      if @thinking
        @log << { kind: :error, text: 'a turn is running — press esc to interrupt it first' }
      elsif @provider.nil?
        @log << { kind: :error, text: 'no provider connected — type /providers' }
      elsif !@provider.respond_to?(:agent_run)
        @log << { kind: :error, text: "#{@provider.label} manages its own conversation history" }
      elsif @messages.empty?
        @log << { kind: :assistant, text: 'Nothing to compact — the conversation is empty.' }
      else
        return false
      end

      true
    end

    def summary_request(focus)
      text = 'Compact this conversation now, following your instructions.'
      text += " The user asked you to keep this in particular: #{focus}" unless focus.empty?
      text
    end

    # Swap the conversation for its summary. Called on the TUI thread when the
    # summarizing turn finishes.
    def apply_compaction(summary)
      @pending_compact = false
      text = summary.to_s.strip

      if text.empty?
        @log << { kind: :error, text: 'compaction produced no summary — the conversation is unchanged' }
        return
      end

      before = Agents.estimate_tokens(@messages)
      @messages = [{ 'role' => 'user', 'content' => compacted_seed(text) }]
      after = Agents.estimate_tokens(@messages)
      @context_tokens = after
      @compact_hinted = false

      @log << { kind: :assistant,
                text: 'Compacted — the conversation above is now the summary shown, roughly ' \
                      "#{Usage.compact(before)} tokens down to #{Usage.compact(after)}. " \
                      'Files on disk are untouched.' }
    end

    # The summary re-enters as the conversation's first user message: providers
    # require the history to open with one, and it reads as context rather than
    # as something the model said.
    def compacted_seed(summary)
      <<~TXT
        This session continues earlier work. The conversation so far was compacted into
        the handover below — treat it as what you know, and re-read any file before
        changing it, since your memory of its contents is gone.

        #{summary}
      TXT
    end
  end
end
