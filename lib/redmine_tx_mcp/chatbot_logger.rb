require 'logger'
require 'fileutils'

module RedmineTxMcp
  class ChatbotLogger
    LOG_FILE = File.join(Rails.root, 'log', 'chatbot_detail.log')

    class << self
      def logger
        @logger ||= begin
          FileUtils.mkdir_p(File.dirname(LOG_FILE))
          l = Logger.new(LOG_FILE, 'daily')
          l.progname = 'ChatbotDetail'
          l.formatter = proc { |_severity, _datetime, _progname, msg| "#{msg}\n" }
          l
        end
      end

      def log_user_query(data)
        lines = []
        lines << ""
        lines << "[#{timestamp}] >>>>>> USER QUERY >>>>>>"
        lines << "session: #{data[:session_id]} | user: #{data[:user_name]}"
        lines << data[:message].to_s
        lines << ""
        logger.info(lines.join("\n"))
      rescue => e
        Rails.logger.warn "[ChatbotLogger] Failed to log user query: #{e.message}"
      end

      def log_api_call(data)
        lines = []
        lines << "[#{timestamp}] === CHATBOT API CALL ==="
        lines << "session: #{data[:session_id]} | user: #{data[:user_name]} | model: #{data[:model]} | provider: #{data[:provider] || '-'}"
        lines << "loop_depth: #{data[:loop_depth]}/#{data[:max_depth]} | stop_reason: #{data[:stop_reason]}"
        lines << "system_prompt: #{format_number(data[:system_prompt_chars])} chars | messages: #{data[:message_count]} (from #{data[:raw_message_count]} raw, budget kept #{data[:budget_message_count] || '?'})"
        lines << "tools_sent: #{data[:tools_count]} definitions#{data[:tool_names] ? " [#{data[:tool_names]}]" : ''}"
        lines << "api_duration: #{data[:api_duration_ms] || 0}ms"
        lines << "--- USAGE ---"
        lines << "input_tokens: #{format_number(data[:input_tokens])} | output_tokens: #{format_number(data[:output_tokens])}"
        lines << ""
        logger.info(lines.join("\n"))
      rescue => e
        Rails.logger.warn "[ChatbotLogger] Failed to log API call: #{e.message}"
      end

      def log_tool_execution(data)
        result_chars = data[:result_chars] || 0
        truncated_chars = data[:truncated_chars]
        duration_ms = data[:duration_ms] || 0
        trunc_info = truncated_chars ? " → truncated to #{format_number(truncated_chars)}" : ""

        lines = []
        lines << "  [tool] #{data[:tool_name]}(#{data[:tool_input]}) → #{format_number(result_chars)} chars#{trunc_info}, #{duration_ms}ms"
        lines << "  ---- result ----"
        lines << indent(data[:result_text].to_s, "  | ")
        lines << "  ---- end ----"
        logger.info(lines.join("\n"))
      rescue => e
        Rails.logger.warn "[ChatbotLogger] Failed to log tool execution: #{e.message}"
      end

      def log_assistant_response(data)
        lines = []
        lines << ""
        lines << "[#{timestamp}] <<<<<< ASSISTANT RESPONSE <<<<<<"
        lines << "session: #{data[:session_id]}"
        lines << data[:message].to_s
        lines << ""
        logger.info(lines.join("\n"))
      rescue => e
        Rails.logger.warn "[ChatbotLogger] Failed to log assistant response: #{e.message}"
      end

      def log_session_summary(data)
        lines = []
        lines << ""
        lines << "[#{timestamp}] === SESSION SUMMARY ==="
        lines << "session: #{data[:session_id]} | api_calls: #{data[:api_calls]} | tool_executions: #{data[:tool_executions]}"
        lines << "stop_reason: #{data[:stop_reason] || 'unknown'} | iterations: #{data[:iteration_count] || 0} | elapsed_in_loop: #{data[:elapsed_ms] || 0}ms"
        lines << "loop_detector: #{data[:loop_detector] || '-'} | remaining_tool_budget: #{data[:remaining_tool_budget] || 0}"
        lines << "providers: #{data[:providers_used].presence || data[:last_provider] || '-'} | fallbacks: #{data[:provider_fallbacks] || 0} | provider_failures: #{data[:provider_failures] || 0}"
        lines << "compaction_runs: #{data[:compaction_runs] || 0} | compacted_messages: #{data[:compacted_messages] || 0} | compacted_chars: #{format_number(data[:compacted_chars] || 0)} | last_compaction_trigger: #{data[:last_compaction_trigger] || '-'}"
        lines << "loop_guard_blocks: #{data[:loop_guard_blocks] || 0} | loop_guard_warnings: #{data[:loop_guard_warnings] || 0} | tool_budget_exhaustions: #{data[:tool_budget_exhaustions] || 0}"
        lines << "verify_successes: #{data[:mutation_verify_successes] || 0} | verify_failures: #{data[:mutation_verify_failures] || 0} | context_overflow_retries: #{data[:context_overflow_retries] || 0}"
        lines << "session_restored: #{data[:session_restored] || false} | restored_follow_up_success: #{data[:restored_follow_up_success] || false} | spreadsheet_workflow_used: #{data[:spreadsheet_workflow_used] || false}"
        lines << "input_tokens: #{format_number(data[:input_tokens])} | output_tokens: #{format_number(data[:output_tokens])}"
        lines << "total_duration: #{data[:total_duration_ms]}ms"
        lines << "history_messages: #{data[:history_message_count] || '?'} | history_chars: #{format_number(data[:history_chars] || 0)}"
        lines << ""
        logger.info(lines.join("\n"))
      rescue => e
        Rails.logger.warn "[ChatbotLogger] Failed to log session summary: #{e.message}"
      end

      def log_stream_event(data)
        lines = []
        lines << "[#{timestamp}] --- STREAM #{data[:event].to_s.upcase} ---"
        lines << "session: #{data[:session_id]} | enum_call: ##{data[:call_count]} | PID: #{data[:pid]} | TID: #{data[:tid]}"
        lines << data[:detail].to_s if data[:detail].present?
        lines << ""
        logger.info(lines.join("\n"))
      rescue => e
        Rails.logger.warn "[ChatbotLogger] Failed to log stream event: #{e.message}"
      end

      def log_error(data)
        lines = []
        lines << "[#{timestamp}] !!! ERROR !!!"
        lines << "session: #{data[:session_id]} | context: #{data[:context]}"
        lines << "#{data[:error_class]}: #{data[:message]}"
        lines << data[:backtrace].first(10).join("\n") if data[:backtrace]
        lines << ""
        logger.error(lines.join("\n"))
      rescue => e
        Rails.logger.warn "[ChatbotLogger] Failed to log error: #{e.message}"
      end

      def log_info(data)
        lines = []
        lines << "[#{timestamp}] #{data[:context]}"
        lines << "session: #{data[:session_id]}" if data[:session_id]
        lines << data[:detail].to_s if data[:detail].present?
        logger.info(lines.join("\n"))
      rescue => e
        Rails.logger.warn "[ChatbotLogger] Failed to log info: #{e.message}"
      end

      private

      def timestamp
        Time.now.strftime('%Y-%m-%d %H:%M:%S')
      end

      def format_number(n)
        return '0' if n.nil?
        n.to_s.gsub(/(\d)(?=(\d{3})+(?!\d))/, '\\1,')
      end

      def indent(text, prefix)
        text.each_line.map { |line| "#{prefix}#{line.rstrip}" }.join("\n")
      end
    end
  end
end
