module RedmineTxMcp
  class ChatbotRunGuard
    StopSignal = Struct.new(:reason, :iteration_count, :elapsed_ms, keyword_init: true)

    DEFAULT_MAX_ITERATIONS = 18
    DEFAULT_MAX_ELAPSED_SECONDS = 120

    attr_reader :max_iterations, :max_elapsed_seconds

    def initialize(max_iterations:, max_elapsed_seconds:, abort_check: nil, now_proc: nil)
      @max_iterations = positive_integer(max_iterations, DEFAULT_MAX_ITERATIONS)
      @max_elapsed_seconds = positive_number(max_elapsed_seconds, DEFAULT_MAX_ELAPSED_SECONDS)
      @abort_check = abort_check
      @now_proc = now_proc || proc { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @started_at = @now_proc.call
    end

    def elapsed_seconds
      [@now_proc.call - @started_at, 0].max
    end

    def elapsed_ms
      (elapsed_seconds * 1000).round
    end

    def check!(iteration_count)
      return stop_signal('abort', iteration_count) if @abort_check&.call
      return stop_signal('timeout', iteration_count) if elapsed_seconds > @max_elapsed_seconds
      return stop_signal('hard_cap', iteration_count) if iteration_count >= @max_iterations

      nil
    end

    private

    def stop_signal(reason, iteration_count)
      StopSignal.new(
        reason: reason,
        iteration_count: iteration_count,
        elapsed_ms: elapsed_ms
      )
    end

    def positive_integer(value, default)
      parsed = Integer(value)
      parsed.positive? ? parsed : default
    rescue ArgumentError, TypeError
      default
    end

    def positive_number(value, default)
      parsed = Float(value)
      parsed.positive? ? parsed : default
    rescue ArgumentError, TypeError
      default
    end
  end
end
