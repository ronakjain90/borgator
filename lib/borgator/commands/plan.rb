# frozen_string_literal: true

require_relative '../plan_mode'

module Commands
  # The /plan command: work read-only until the user says otherwise.
  # Mixed into AgentApp. `/plan` toggles; `/plan on` and `/plan off` are
  # explicit, so a script or a distracted user can't flip it the wrong way.
  module Plan
    def handle_plan(arg = nil)
      if @thinking
        @log << { kind: :error, text: 'a turn is running — press esc to interrupt it first' }
        return [self, nil]
      end

      case arg.to_s.strip.downcase
      when '', 'toggle' then apply_plan_mode(!PlanMode.active?)
      when 'on', 'start' then apply_plan_mode(true)
      when 'off', 'stop', 'end' then apply_plan_mode(false)
      else
        @log << { kind: :error, text: "unknown argument #{arg.inspect} — use /plan, /plan on, or /plan off" }
      end

      [self, nil]
    end

    # " · plan" for the composer, or nil in normal mode.
    def plan_mode_badge
      PlanMode.active? ? '  ◦ plan' : nil
    end

    private

    def apply_plan_mode(active)
      already = PlanMode.active? == active
      active ? PlanMode.enable! : PlanMode.disable!

      if active
        @log << { kind: :assistant, text: already ? 'Already in plan mode.' : 'Plan mode on.' }
        @log << { kind: :tool_result, text: '  read-only: no file writes, and only read-only shell commands' }
        @log << { kind: :tool_result, text: '  ask for what you want; /plan again to carry it out' }
      else
        @log << { kind: :assistant, text: already ? 'Not in plan mode.' : 'Plan mode off — writing tools are back.' }
      end
    end
  end
end
