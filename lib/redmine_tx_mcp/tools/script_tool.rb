require 'stringio'
require 'date'
require 'set'
require 'json'
require 'timeout'

module RedmineTxMcp
  module Tools
    class ScriptTool < BaseTool
      TIMEOUT_SECONDS = 5
      MAX_OUTPUT_CHARS = 8_000

      # Patterns that indicate dangerous operations
      FORBIDDEN_PATTERNS = [
        /\b(require|load|autoload)\b/,
        /\b(system|exec|spawn|fork|popen|syscall)\b/,
        /`[^`]*`/,                          # backticks
        /\b(File|Dir|IO|Pathname|Tempfile|FileUtils)\b/,
        /\b(Net|HTTP|URI|Socket|TCPSocket|UDPSocket|Open3|OpenURI)\b/,
        /\b(Open3|Kernel\.open|open\s*\(?\s*['"|])/,
        /\b(__method__|__dir__|__FILE__|__LINE__|__ENCODING__)\b/,
        /\b(send|public_send|method|define_method|instance_eval|class_eval|module_eval)\b/,
        /\b(eval|binding|Binding)\b/,
        /\b(ObjectSpace|GC|Process|Signal|Fiber|Thread|Mutex|Ractor)\b/,
        /\b(ENV|ARGV|STDIN|STDOUT|STDERR)\b/,
        /\b(Gem|Bundler|Rails|ActiveRecord|ActiveSupport|ActionController)\b/,
        /\b(Issue|Project|User|Version|Tracker|IssueStatus|Setting|Redmine)\b/,
        /\b(Marshal|YAML|Psych|CSV)\b/,
        /\b(at_exit|exit|abort|trap|sleep)\b/,
        /\b(\.class_eval|\.instance_eval|\.module_eval)\b/,
        /\$[A-Z]/,                           # global variables like $LOAD_PATH
      ].freeze

      ALLOWED_CLASSES = %w[
        Integer Float String Array Hash Symbol NilClass TrueClass FalseClass
        Numeric Comparable Enumerable Math Range Regexp MatchData
        Date Time DateTime Rational Complex Set
      ].freeze

      class << self
        def available_tools
          [
            {
              name: "run_script",
              description: <<~DESC.strip,
                Execute a short Ruby script for calculations, data processing, or analysis.
                Use this when you need accurate arithmetic, date math, statistical calculations,
                sorting/ranking, or data transformations that are error-prone to do mentally.
                The script runs in a sandboxed environment with no file/network/database access.
                Available: basic Ruby, Math, Date, Time, Set. Print results with `puts` or
                return a final expression value. Both stdout and the final expression are captured.
              DESC
              inputSchema: {
                type: "object",
                properties: {
                  script: {
                    type: "string",
                    description: "Ruby script to execute. Keep it short and focused on computation. No file I/O, network, or database access."
                  },
                  context: {
                    type: "string",
                    description: "Optional: brief note on what this script calculates (for logging)"
                  }
                },
                required: ["script"]
              }
            }
          ]
        end

        def call_tool(tool_name, arguments)
          arguments.delete('_chatbot_context')
          arguments.delete('_chatbot_workspace')

          case tool_name
          when "run_script"
            run_script(arguments)
          else
            { error: "Unknown tool: #{tool_name}" }
          end
        rescue => e
          handle_error(e)
        end

        private

        def run_script(args)
          script = (args['script'] || '').to_s.strip
          return { error: "Script is empty" } if script.empty?

          # Security: reject dangerous patterns
          violation = check_forbidden_patterns(script)
          return { error: "Blocked: #{violation}" } if violation

          execute_sandboxed(script)
        end

        def check_forbidden_patterns(script)
          FORBIDDEN_PATTERNS.each do |pattern|
            if script.match?(pattern)
              match = script.match(pattern)
              return "forbidden pattern detected: `#{match[0]}`"
            end
          end
          nil
        end

        def execute_sandboxed(script)
          captured_io = StringIO.new
          sandbox = create_sandbox

          # Wrap script to capture both puts output and return value
          wrapped = <<~RUBY
            __output_io__ = $stdout
            $stdout = __captured_io__
            begin
              __result__ = begin
                #{script}
              end
              $stdout = __output_io__
              [__captured_io__.string, __result__, nil]
            rescue => e
              $stdout = __output_io__
              [__captured_io__.string, nil, "\#{e.class}: \#{e.message}"]
            end
          RUBY

          sandbox.local_variable_set(:__captured_io__, captured_io)

          output, result_value, error = Timeout.timeout(TIMEOUT_SECONDS) do
            sandbox.eval(wrapped, "(script)", 0)
          end

          if error
            return { error: error, stdout: truncate_output(output) }
          end

          build_result(output, result_value)
        rescue Timeout::Error
          # Restore stdout in case it was redirected when timeout hit
          $stdout = STDOUT unless $stdout == STDOUT
          { error: "Script timed out after #{TIMEOUT_SECONDS} seconds" }
        rescue SyntaxError => e
          $stdout = STDOUT unless $stdout == STDOUT
          { error: "SyntaxError: #{e.message.sub(/\(script\):\d+:\s*/, '')}" }
        rescue => e
          $stdout = STDOUT unless $stdout == STDOUT
          { error: "#{e.class}: #{e.message}" }
        end

        def create_sandbox
          # Create a clean binding with only safe utilities
          TOPLEVEL_BINDING.dup
        end

        def build_result(output, result_value)
          parts = {}

          stdout = truncate_output(output)
          parts[:stdout] = stdout if stdout && !stdout.empty?

          if result_value != nil
            formatted = format_result_value(result_value)
            parts[:result] = formatted if formatted != stdout&.strip
          end

          parts.empty? ? { result: "(no output)" } : parts
        end

        def format_result_value(value)
          case value
          when String
            value
          when Array, Hash
            JSON.pretty_generate(value)
          else
            value.inspect
          end
        rescue
          value.to_s
        end

        def truncate_output(str)
          return nil if str.nil?
          str = str.to_s
          if str.length > MAX_OUTPUT_CHARS
            str[0...MAX_OUTPUT_CHARS] + "\n... (truncated, #{str.length} chars total)"
          else
            str
          end
        end
      end
    end
  end
end
