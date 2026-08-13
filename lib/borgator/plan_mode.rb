# frozen_string_literal: true

require_relative 'tools/support'

# Read-only mode: the agent investigates and proposes, but changes nothing.
#
# Enforced in three places, deliberately. The mutating tools are withheld from
# the model's tool list so it plans instead of trying (1); `Tools.call` refuses
# them anyway, so a model that names a tool it wasn't offered still can't write
# (2); and `run_command` accepts only commands on the built-in read-only
# allowlist, so the shell isn't a way around the first two (3).
#
# The state is process-wide rather than per-agent because worker agents run on
# their own threads through the same tool layer — the same reason
# {Tools.approver} lives there. It is session-only: a new run starts in normal
# mode, so nobody is silently left unable to edit.
module PlanMode
  # Tools that change the project. Everything else is inspection.
  MUTATING_TOOLS = %w[write_file edit_file].freeze

  SYSTEM_NOTE = <<~TXT
    PLAN MODE IS ACTIVE. You cannot change anything: `write_file` and `edit_file` are
    unavailable, and `run_command` will only run read-only commands. Do not attempt
    workarounds — investigate with the read tools and answer with a plan.

    Produce a concrete plan: the files you would change, what each change is, and how
    you would verify it. Say what you are unsure about rather than guessing. The user
    will leave plan mode with `/plan` when they want the work carried out.
  TXT

  class << self
    def active?
      @active ? true : false
    end

    def enable!
      @active = true
    end

    def disable!
      @active = false
    end

    # Returns the new state.
    def toggle!
      @active = !active?
    end

    # Tool schemas to expose, minus anything that writes while planning.
    def filter_tools(definitions)
      return definitions unless active?

      definitions.reject { |tool| MUTATING_TOOLS.include?((tool[:name] || tool['name']).to_s) }
    end

    # Why this tool call was refused, or nil when it may proceed.
    def refusal(tool_name)
      return nil unless active? && MUTATING_TOOLS.include?(tool_name.to_s)

      "Refused: plan mode is active, so `#{tool_name}` is unavailable and nothing was " \
        'changed. Describe the change in your plan instead; the user will leave plan ' \
        'mode when they want it carried out.'
    end

    # Why this shell command was refused, or nil when it may run. Only the
    # built-in read-only prefixes pass — a command the user once approved
    # permanently may well write, and permission is not the question here.
    def command_refusal(command)
      return nil unless active?
      return nil if Tools.read_only?(command)

      'Refused: plan mode is active, so only read-only commands run and this one did ' \
        "not: #{command}. Inspect with the read tools, or include the command in your " \
        'plan for the user to run after leaving plan mode.'
    end
  end
end
