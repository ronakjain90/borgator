# frozen_string_literal: true

require_relative '../sessions'

module Commands
  # The /resume command: reopen one of this project's saved conversations.
  # Mixed into AgentApp, so it works on the app's state (@messages, @log, @mode,
  # …) and reuses the shared list-picker helpers.
  #
  # Only sessions in the current provider's wire format are offered — Anthropic
  # content blocks and OpenAI tool_calls are not interchangeable, and replaying
  # the wrong shape would be rejected by the API on the next turn.
  module Resume
    def open_resume_picker
      unless @provider
        @log << { kind: :error, text: 'connect a provider first — type /providers' }
        return [self, nil]
      end

      shape = Sessions.shape_of(@provider)
      entries = shape ? Sessions.recent(shape: shape) : []
      entries = entries.reject { |entry| entry[:id] == @session_id }
      if entries.empty?
        @log << { kind: :assistant, text: no_sessions_message(shape) }
        return [self, nil]
      end

      @resume_picker_items = entries
      @mode = :resume_picker
      @menu_cursor = 0
      @menu_scroll = 0
      [self, nil]
    end

    def update_resume_picker(message)
      update_list_picker(message, @resume_picker_items) { confirm_resume_selection }
    end

    def view_resume_picker
      lines = [@bot.render('Resume a conversation')]
      lines << @hint.render("  #{@provider.label} · #{@provider.model_label} — this project's saved sessions")

      visible = @resume_picker_items[@menu_scroll, list_menu_budget] || []
      visible.each_with_index do |entry, i|
        selected = (@menu_scroll + i) == @menu_cursor
        prefix = selected ? '> ' : '  '
        text = "#{resume_age(entry)}  ·  #{entry[:turns]} turn#{'s' if entry[:turns] != 1}  ·  #{entry[:title]}"
        lines << (selected ? @you.render("#{prefix}#{text}") : @hint.render("#{prefix}#{text}"))
      end

      lines << ''
      lines << @hint.render('up/down move | enter resume | esc back | ctrl+c quit')
      lines.join("\n")
    end

    # Save after each completed (or interrupted) turn, so quitting costs
    # nothing. Failures are swallowed by Sessions — persistence is a
    # convenience and must never take a turn down with it.
    def persist_session
      return unless @provider

      Sessions.save(id: @session_id, provider: @provider, messages: @messages, log: @log)
    end

    # Start a new saved session. Called wherever @messages is cleared, so a
    # fresh conversation never appends to the previous one's file.
    def reset_session!
      @session_id = Sessions.new_id
    end

    private

    def no_sessions_message(shape)
      return "#{@provider.label} manages its own conversation history — nothing to resume here." if shape.nil? ||
                                                                                                    shape == 'opencode'

      'No saved conversations for this project yet — they are saved as you go.'
    end

    def resume_age(entry)
      Sessions.age(Time.parse(entry[:updated_at]))
    rescue StandardError
      'earlier'
    end

    def confirm_resume_selection
      item = @resume_picker_items[@menu_cursor]
      @mode = :chat
      @resume_picker_items = []
      return [self, nil] unless item

      session = Sessions.load(item[:id])
      if session.nil? || session[:messages].empty?
        @log << { kind: :error, text: 'that session could not be read — it may have been pruned' }
        return [self, nil]
      end

      restore_session(session)
      [self, nil]
    end

    # Replace the live conversation with the saved one. The checkpoint stack is
    # left alone: it tracks files on disk now, which resuming does not change.
    def restore_session(session)
      @session_id = session[:id]
      @messages = session[:messages]
      @log = session[:log].dup
      @diffs = []
      @diff_cursor = -1
      @usage = Usage.blank
      @context_tokens = Agents.estimate_tokens(@messages)
      turns = @messages.count { |msg| msg['role'] == 'user' }
      @log << { kind: :assistant,
                text: "Resumed \"#{session[:title]}\" — #{turns} turn#{'s' if turns != 1} restored; " \
                      'the model has the full history again.' }
    end
  end
end
