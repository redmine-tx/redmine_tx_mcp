require 'digest'
require 'json'

module RedmineTxMcp
  class ChatbotLoopGuard
    Decision = Struct.new(
      :blocked,
      :level,
      :detector,
      :count,
      :message,
      :warning_key,
      :emit_warning,
      :paired_tool_name,
      keyword_init: true
    )

    Record = Struct.new(
      :tool_name,
      :args_hash,
      :result_hash,
      :tool_call_id,
      :is_error,
      :timestamp_ms,
      keyword_init: true
    )

    DEFAULT_CONFIG = {
      history_size: 24,
      generic_repeat_warn: 4,
      no_progress_warn: 4,
      no_progress_block: 6,
      ping_pong_warn: 4,
      ping_pong_block: 6,
      global_breaker_block: 8,
      warning_bucket_size: 2
    }.freeze

    HASH_CLIP_HEAD_CHARS = 1_500
    HASH_CLIP_TAIL_CHARS = 500
    HASH_CLIP_MARKER = "\n...[hash clip]...\n".freeze
    UNSTABLE_KEYS = %w[
      timestamp request_id trace_id fetched_at updated_at created_at
    ].freeze

    attr_reader :loop_evidence_count

    def initialize(config = {})
      @config = DEFAULT_CONFIG.merge((config || {}).transform_keys(&:to_sym))
      @history = []
      @warning_buckets = {}
      @loop_evidence_count = 0
    end

    def projected_repeat_count(tool_name, params)
      signature = hash_tool_call(tool_name, params)
      1 + @history.count { |record| record.tool_name == tool_name && record.args_hash == signature }
    end

    def record_call(tool_name, params, tool_call_id: nil)
      @history << Record.new(
        tool_name: tool_name.to_s,
        args_hash: hash_tool_call(tool_name, params),
        tool_call_id: tool_call_id,
        timestamp_ms: (Time.now.to_f * 1000).round
      )
      trim_history!
    end

    def record_outcome(tool_name, params, result, is_error: false, tool_call_id: nil)
      signature = hash_tool_call(tool_name, params)
      result_hash = hash_tool_outcome(result, is_error: is_error)
      record = find_open_record(tool_name, signature, tool_call_id: tool_call_id)

      if record
        record.result_hash = result_hash
        record.is_error = is_error
      else
        @history << Record.new(
          tool_name: tool_name.to_s,
          args_hash: signature,
          tool_call_id: tool_call_id,
          result_hash: result_hash,
          is_error: is_error,
          timestamp_ms: (Time.now.to_f * 1000).round
        )
        trim_history!
      end

      record_confirmed_loop_evidence(tool_name.to_s, signature)
    end

    def detect_before_call(tool_name, params)
      tool = tool_name.to_s
      signature = hash_tool_call(tool, params)
      repeat_count = projected_repeat_count(tool, params)
      no_progress_count, latest_result_hash = no_progress_streak(tool, signature)
      projected_no_progress = latest_result_hash ? no_progress_count + 1 : 0
      ping_pong = projected_ping_pong(signature)

      decision =
        if projected_no_progress >= @config[:no_progress_block]
          Decision.new(
            blocked: true,
            level: 'critical',
            detector: 'no_progress',
            count: projected_no_progress,
            message: "같은 도구 호출이 같은 결과로 #{projected_no_progress}회 반복되어 추가 실행을 차단했습니다.",
            warning_key: "no_progress:#{tool}:#{signature}:#{latest_result_hash}"
          )
        elsif ping_pong[:no_progress] && ping_pong[:count] >= @config[:ping_pong_block]
          Decision.new(
            blocked: true,
            level: 'critical',
            detector: 'ping_pong',
            count: ping_pong[:count],
            message: "반복되는 도구 패턴이 #{ping_pong[:count]}회 이어져 추가 실행을 차단했습니다.",
            warning_key: "ping_pong:#{signature}:#{ping_pong[:paired_signature]}",
            paired_tool_name: ping_pong[:paired_tool_name]
          )
        elsif projected_no_progress >= @config[:no_progress_warn]
          Decision.new(
            blocked: false,
            level: 'warning',
            detector: 'no_progress',
            count: projected_no_progress,
            message: "같은 도구 호출이 같은 결과로 #{projected_no_progress}회 반복 중입니다.",
            warning_key: "no_progress:#{tool}:#{signature}:#{latest_result_hash}"
          )
        elsif ping_pong[:no_progress] && ping_pong[:count] >= @config[:ping_pong_warn]
          Decision.new(
            blocked: false,
            level: 'warning',
            detector: 'ping_pong',
            count: ping_pong[:count],
            message: "반복되는 도구 패턴이 #{ping_pong[:count]}회 이어지고 있습니다.",
            warning_key: "ping_pong:#{signature}:#{ping_pong[:paired_signature]}",
            paired_tool_name: ping_pong[:paired_tool_name]
          )
        elsif repeat_count >= @config[:generic_repeat_warn]
          Decision.new(
            blocked: false,
            level: 'warning',
            detector: 'generic_repeat',
            count: repeat_count,
            message: "같은 도구 호출이 #{repeat_count}회 반복 중입니다.",
            warning_key: "generic_repeat:#{tool}:#{signature}"
          )
        else
          Decision.new(blocked: false, count: 0, emit_warning: false)
        end

      if %w[no_progress ping_pong].include?(decision.detector) && decision.level == 'critical'
        projected_evidence = @loop_evidence_count + 1
        if projected_evidence >= @config[:global_breaker_block]
          decision = Decision.new(
            blocked: true,
            level: 'critical',
            detector: 'global_breaker',
            count: projected_evidence,
            message: "세션 전체 loop evidence가 #{projected_evidence}회 누적되어 추가 실행을 차단했습니다.",
            warning_key: 'global_breaker'
          )
        end
      end

      if decision.level == 'warning' && decision.warning_key
        decision.emit_warning = should_emit_warning?(decision.warning_key, decision.count)
      end

      decision
    end

    def self.format_warning_note(decision)
      return '' unless decision&.level == 'warning'

      case decision.detector
      when 'generic_repeat'
        "[참고: 같은 호출이 #{decision.count}회째 반복 중]"
      when 'no_progress'
        "[참고: 같은 결과가 #{decision.count}회째 반복 중, 전략 변경이 필요할 수 있음]"
      when 'ping_pong'
        "[참고: 반복 패턴이 #{decision.count}회째 이어지는 중, 같은 전략 재시도는 피하는 편이 좋음]"
      else
        ''
      end
    end

    def self.format_block_message(decision)
      return '' unless decision&.blocked

      case decision.detector
      when 'no_progress'
        "같은 도구 호출이 같은 결과로 #{decision.count}회 반복되어 더 이상 실행하지 않았습니다. 현재 상태를 요약하고 다른 전략을 선택하세요."
      when 'ping_pong'
        paired = decision.paired_tool_name ? " (#{decision.paired_tool_name}와 번갈아)" : ''
        "반복되는 도구 패턴#{paired}이 #{decision.count}회 이어져 더 이상 실행하지 않았습니다. 현재 상태를 요약하고 다른 전략을 선택하세요."
      when 'global_breaker'
        "세션 전체에서 루프 신호가 #{decision.count}회 누적되어 추가 실행을 차단했습니다. 현재 상태를 설명하고 같은 시도를 반복하지 말고 실패 또는 대안 전략을 보고하세요."
      else
        message = decision.message.to_s
        message.empty? ? "반복되는 도구 호출이 감지되어 추가 실행을 차단했습니다. 현재 상태를 설명하고 다른 전략을 선택하세요." : message
      end
    end

    private

    def trim_history!
      overflow = @history.length - @config[:history_size]
      @history.shift(overflow) if overflow.positive?
    end

    def find_open_record(tool_name, signature, tool_call_id: nil)
      @history.reverse_each do |record|
        next if tool_call_id && record.tool_call_id != tool_call_id
        next unless record.tool_name == tool_name.to_s && record.args_hash == signature
        next if record.result_hash

        return record
      end
      nil
    end

    def should_emit_warning?(warning_key, count)
      bucket_size = [@config[:warning_bucket_size].to_i, 1].max
      bucket = count / bucket_size
      last_bucket = @warning_buckets[warning_key]
      return false if !last_bucket.nil? && bucket <= last_bucket

      @warning_buckets[warning_key] = bucket
      true
    end

    def record_confirmed_loop_evidence(tool_name, signature)
      no_progress_count, latest_result_hash = no_progress_streak(tool_name, signature)
      if latest_result_hash && no_progress_count >= @config[:no_progress_warn]
        @loop_evidence_count += 1
        return
      end

      ping_pong = ping_pong_streak
      if ping_pong[:no_progress] && ping_pong[:count] >= @config[:ping_pong_warn]
        @loop_evidence_count += 1
      end
    end

    def no_progress_streak(tool_name, signature)
      streak = 0
      latest_result_hash = nil

      @history.reverse_each do |record|
        next unless record.tool_name == tool_name.to_s && record.args_hash == signature
        next unless record.result_hash

        if latest_result_hash.nil?
          latest_result_hash = record.result_hash
          streak = 1
        elsif record.result_hash == latest_result_hash
          streak += 1
        else
          break
        end
      end

      [streak, latest_result_hash]
    end

    def ping_pong_streak
      last = @history.last
      return empty_ping_pong if last.nil?

      other = @history[0...-1].reverse.find { |record| record.args_hash != last.args_hash }
      return empty_ping_pong if other.nil?

      alternating_tail_count = 0
      expected = last.args_hash

      @history.reverse_each do |record|
        break unless record.args_hash == expected

        alternating_tail_count += 1
        expected = (expected == last.args_hash ? other.args_hash : last.args_hash)
      end

      return empty_ping_pong if alternating_tail_count < 2

      tail_records = @history.last(alternating_tail_count)
      first_hash_a = nil
      first_hash_b = nil
      no_progress = true

      tail_records.each do |record|
        unless record.result_hash
          no_progress = false
          break
        end

        if record.args_hash == last.args_hash
          if first_hash_a.nil?
            first_hash_a = record.result_hash
          elsif first_hash_a != record.result_hash
            no_progress = false
            break
          end
        elsif record.args_hash == other.args_hash
          if first_hash_b.nil?
            first_hash_b = record.result_hash
          elsif first_hash_b != record.result_hash
            no_progress = false
            break
          end
        else
          no_progress = false
          break
        end
      end

      no_progress = false if first_hash_a.nil? || first_hash_b.nil?

      {
        count: alternating_tail_count,
        paired_tool_name: other.tool_name,
        paired_signature: other.args_hash,
        next_signature: other.args_hash,
        no_progress: no_progress
      }
    end

    def projected_ping_pong(current_signature)
      streak = ping_pong_streak
      return empty_ping_pong unless streak[:no_progress]
      return empty_ping_pong unless streak[:next_signature] == current_signature

      {
        count: streak[:count] + 1,
        paired_tool_name: streak[:paired_tool_name],
        paired_signature: streak[:paired_signature],
        next_signature: streak[:next_signature],
        no_progress: true
      }
    end

    def empty_ping_pong
      {
        count: 0,
        paired_tool_name: nil,
        paired_signature: nil,
        next_signature: nil,
        no_progress: false
      }
    end

    def hash_tool_call(tool_name, params)
      serialized = stable_json(
        'tool' => tool_name.to_s,
        'params' => params
      )
      "#{tool_name}:#{Digest::SHA256.hexdigest(serialized)}"
    end

    def hash_tool_outcome(result, is_error: false)
      normalized = normalize_tool_result(result, is_error: is_error)
      Digest::SHA256.hexdigest(clip_text(stable_json(normalized)))
    end

    def normalize_tool_result(result, is_error: false)
      case result
      when Hash
        strip_unstable_fields(result).merge('is_error' => is_error)
      when Array
        { 'items' => result.map { |item| strip_unstable_fields(item) }, 'is_error' => is_error }
      when String
        parsed = safely_parse_json(result)
        if parsed
          { 'value' => strip_unstable_fields(parsed), 'is_error' => is_error }
        else
          { 'text' => clip_text(result), 'is_error' => is_error }
        end
      when Exception
        { 'error_type' => result.class.name, 'message' => clip_text(result.message), 'is_error' => true }
      when NilClass
        { 'value' => nil, 'is_error' => is_error }
      else
        { 'text' => clip_text(result.to_s), 'is_error' => is_error }
      end
    end

    def safely_parse_json(value)
      return nil unless value.is_a?(String)
      stripped = value.strip
      return nil unless stripped.start_with?('{', '[')

      JSON.parse(stripped)
    rescue JSON::ParserError
      nil
    end

    def strip_unstable_fields(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), normalized|
          next if unstable_key?(key)

          normalized[key.to_s] = strip_unstable_fields(item)
        end
      when Array
        value.map { |item| strip_unstable_fields(item) }
      else
        value
      end
    end

    def unstable_key?(key)
      lowered = key.to_s.strip.downcase
      UNSTABLE_KEYS.include?(lowered) || lowered.end_with?('_at', '_on')
    end

    def stable_json(value)
      JSON.generate(sort_keys(value))
    end

    def sort_keys(value)
      case value
      when Hash
        value.keys.sort_by(&:to_s).each_with_object({}) do |key, sorted|
          sorted[key.to_s] = sort_keys(value[key])
        end
      when Array
        value.map { |item| sort_keys(item) }
      else
        value
      end
    end

    def clip_text(text)
      value = text.to_s
      limit = HASH_CLIP_HEAD_CHARS + HASH_CLIP_TAIL_CHARS
      return value if value.length <= limit

      "#{value[0...HASH_CLIP_HEAD_CHARS]}#{HASH_CLIP_MARKER}#{value[-HASH_CLIP_TAIL_CHARS..]}"
    end
  end
end
