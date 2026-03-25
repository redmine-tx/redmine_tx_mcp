require 'json'
require 'set'

module RedmineTxMcp
  class ChatbotMutationWorkflow
    FOLLOW_UP_REFERENCE_REGEX = /
      계속|이어(?:서)?|아까|방금|그\s*(?:이슈|파일|항목|것)|찾은\s*것들|방금\s*올린\s*파일|
      continue|keep\s+going|that\s+issue|that\s+file|those\s+items
    /ix

    STATUS_VALUES = %w[
      idle
      intent_detected
      target_resolved
      change_resolved
      write_executed
      verify_succeeded
      failed
    ].freeze

    READ_ONLY_PATTERNS = [
      /\Aissue_(list|get|relations_get|children_summary|schedule_tree|auto_schedule_preview)\z/,
      /\Abug_statistics\z/,
      /\Aversion_(list|get|overview|statistics|schedule_report)\z/,
      /\Aproject_(list|get|members)\z/,
      /\Auser_(list|get|projects|groups|roles)\z/,
      /\Aspreadsheet_(list_uploads|list_sheets|preview_sheet|extract_rows)\z/,
      /\Aenum_/,
      /\Arun_script\z/
    ].freeze

    EXPLICIT_TOOL_METADATA = {
      'issue_list' => { read_only: true, entity_type: 'issue', idempotent: true },
      'issue_get' => { read_only: true, entity_type: 'issue', idempotent: true },
      'issue_relations_get' => { read_only: true, entity_type: 'issue_relation', idempotent: true },
      'issue_children_summary' => { read_only: true, entity_type: 'issue', idempotent: true },
      'issue_schedule_tree' => { read_only: true, entity_type: 'issue', idempotent: true },
      'issue_create' => { side_effecting: true, verify_with: %w[issue_get], entity_type: 'issue' },
      'issue_update' => { side_effecting: true, verify_with: %w[issue_get], entity_type: 'issue' },
      'insert_bulk_update' => { side_effecting: true, verify_with: %w[issue_get issue_list], entity_type: 'issue' },
      'issue_delete' => { side_effecting: true, confirm_required: true, entity_type: 'issue' },
      'issue_relation_create' => { side_effecting: true, verify_with: %w[issue_relations_get issue_get], entity_type: 'issue_relation' },
      'issue_relation_delete' => { side_effecting: true, verify_with: %w[issue_relations_get issue_get], entity_type: 'issue_relation' },
      'issue_auto_schedule_preview' => { read_only: true, entity_type: 'issue', idempotent: true },
      'issue_auto_schedule_apply' => { side_effecting: true, verify_with: %w[issue_get issue_schedule_tree], entity_type: 'issue' },
      'version_list' => { read_only: true, entity_type: 'version', idempotent: true },
      'version_get' => { read_only: true, entity_type: 'version', idempotent: true },
      'version_overview' => { read_only: true, entity_type: 'version', idempotent: true },
      'version_schedule_report' => { read_only: true, entity_type: 'version', idempotent: true },
      'version_create' => { side_effecting: true, verify_with: %w[version_get], entity_type: 'version' },
      'version_update' => { side_effecting: true, verify_with: %w[version_get], entity_type: 'version' },
      'version_delete' => { side_effecting: true, confirm_required: true, entity_type: 'version' },
      'project_list' => { read_only: true, entity_type: 'project', idempotent: true },
      'project_get' => { read_only: true, entity_type: 'project', idempotent: true },
      'project_members' => { read_only: true, entity_type: 'project', idempotent: true },
      'project_create' => { side_effecting: true, verify_with: %w[project_get], entity_type: 'project' },
      'project_update' => { side_effecting: true, verify_with: %w[project_get], entity_type: 'project' },
      'project_delete' => { side_effecting: true, confirm_required: true, entity_type: 'project' },
      'project_add_member' => { side_effecting: true, verify_with: %w[project_members], entity_type: 'project' },
      'project_remove_member' => { side_effecting: true, verify_with: %w[project_members], entity_type: 'project' },
      'user_list' => { read_only: true, entity_type: 'user', idempotent: true },
      'user_get' => { read_only: true, entity_type: 'user', idempotent: true },
      'user_projects' => { read_only: true, entity_type: 'user', idempotent: true },
      'user_groups' => { read_only: true, entity_type: 'user', idempotent: true },
      'user_roles' => { read_only: true, entity_type: 'user', idempotent: true },
      'user_create' => { side_effecting: true, verify_with: %w[user_get], entity_type: 'user' },
      'user_update' => { side_effecting: true, verify_with: %w[user_get], entity_type: 'user' },
      'user_delete' => { side_effecting: true, confirm_required: true, entity_type: 'user' },
      'spreadsheet_list_uploads' => { read_only: true, entity_type: 'spreadsheet', idempotent: true },
      'spreadsheet_list_sheets' => { read_only: true, entity_type: 'spreadsheet', idempotent: true },
      'spreadsheet_preview_sheet' => { read_only: true, entity_type: 'spreadsheet', idempotent: true },
      'spreadsheet_extract_rows' => { read_only: true, entity_type: 'spreadsheet', idempotent: true },
      'spreadsheet_export_report' => { side_effecting: true, verification_required: false, entity_type: 'spreadsheet_report', idempotent: false },
      'run_script' => { read_only: true, entity_type: 'script', idempotent: true }
    }.freeze

    REQUESTED_CHANGE_IGNORED_FIELDS = %w[
      _chatbot_context _chatbot_workspace allow_partial_success preview_token
      file_name rows columns summary_lines
    ].freeze

    ISSUE_FIELD_READERS = {
      'subject' => %w[subject],
      'description' => %w[description],
      'status_id' => [%w[status id], %w[status_id]],
      'priority_id' => [%w[priority id], %w[priority_id]],
      'assigned_to_id' => [%w[assigned_to id], %w[assigned_to_id]],
      'category_id' => [%w[category id], %w[category_id]],
      'fixed_version_id' => [%w[fixed_version id], %w[fixed_version_id], %w[version id]],
      'parent_issue_id' => [%w[parent id], %w[parent_issue_id]],
      'project_id' => [%w[project id], %w[project_id]],
      'tracker_id' => [%w[tracker id], %w[tracker_id]],
      'start_date' => %w[start_date],
      'due_date' => %w[due_date],
      'estimated_hours' => %w[estimated_hours],
      'done_ratio' => %w[done_ratio]
    }.freeze

    def self.metadata_for(tool_name)
      tool = tool_name.to_s
      explicit = EXPLICIT_TOOL_METADATA[tool] || {}
      inferred = inferred_metadata_for(tool)
      read_only = explicit.key?(:read_only) ? explicit[:read_only] : inferred[:read_only]
      side_effecting = explicit.key?(:side_effecting) ? explicit[:side_effecting] : inferred[:side_effecting]
      verify_with = Array(explicit.key?(:verify_with) ? explicit[:verify_with] : inferred[:verify_with]).map(&:to_s).uniq
      {
        read_only: read_only,
        side_effecting: side_effecting,
        idempotent: explicit.key?(:idempotent) ? explicit[:idempotent] : inferred[:idempotent],
        confirm_required: explicit.key?(:confirm_required) ? explicit[:confirm_required] : inferred[:confirm_required],
        verify_with: verify_with,
        verification_required: explicit.key?(:verification_required) ? explicit[:verification_required] : (side_effecting && verify_with.any?),
        entity_type: (explicit[:entity_type] || inferred[:entity_type]).to_s
      }
    end

    def self.read_only_tool?(tool_name)
      metadata_for(tool_name)[:read_only]
    end

    def self.side_effecting_tool?(tool_name)
      metadata_for(tool_name)[:side_effecting]
    end

    def self.follow_up_reference?(message)
      FOLLOW_UP_REFERENCE_REGEX.match?(message.to_s)
    end

    def initialize(state = nil)
      restore!(state)
    end

    def restore!(state)
      @state = normalize_state(state)
      self
    end

    def export_state
      deep_dup(@state)
    end

    def mark_intent(user_message, mutation:)
      return unless mutation
      return if pending_verification?

      @state['intent'] = {
        'message' => user_message.to_s
      }
      @state['status'] = 'intent_detected'
    end

    def pending_mutation
      hash_or_nil(@state['pending_mutation'])
    end

    def status
      @state['status'].to_s
    end

    def pending?
      !!(pending_mutation && pending_mutation['verification_status'] != 'passed')
    end

    def pending_verification?
      !!(pending_mutation && pending_mutation['verification_required'] && pending_mutation['verification_status'] == 'pending')
    end

    def verification_failed?
      !!(pending_mutation && pending_mutation['verification_status'] == 'failed')
    end

    def verify_with_tools
      pending = pending_mutation
      pending ? Array(pending['verify_with']).map(&:to_s).uniq : []
    end

    def active_workspace_file
      value = @state['active_workspace_file']
      blank_string?(value) ? nil : value.to_s
    end

    def active_sheet_name
      value = @state['active_sheet_name']
      blank_string?(value) ? nil : value.to_s
    end

    def resolved_entities
      deep_dup(@state['resolved_entities'])
    end

    def has_follow_up_context?
      pending? || resolved_entities.values.any? { |values| Array(values).any? } || !blank_string?(active_workspace_file)
    end

    def follow_up_tool_names
      tools = Set.new
      pending = pending_mutation

      if pending
        tools << pending['tool'].to_s if pending['tool']
        Array(pending['verify_with']).each { |name| tools << name.to_s }
      end

      if Array(@state.dig('resolved_entities', 'issue_ids')).any?
        tools.merge(%w[issue_list issue_get issue_relations_get issue_update insert_bulk_update])
      end

      if Array(@state.dig('resolved_entities', 'version_ids')).any?
        tools.merge(%w[version_list version_get version_overview version_update])
      end

      if Array(@state.dig('resolved_entities', 'project_ids')).any?
        tools.merge(%w[project_list project_get project_members project_update])
      end

      if Array(@state.dig('resolved_entities', 'user_ids')).any?
        tools.merge(%w[user_list user_get user_update])
      end

      unless blank_string?(active_workspace_file)
        tools.merge(%w[
          spreadsheet_list_uploads spreadsheet_list_sheets spreadsheet_preview_sheet
          spreadsheet_extract_rows spreadsheet_export_report
        ])
      end

      tools.to_a
    end

    def prompt_context
      lines = []
      pending = pending_mutation
      if pending
        targets = Array(pending['target_issue_ids']) +
                  Array(pending['target_version_ids']) +
                  Array(pending['target_project_ids']) +
                  Array(pending['target_user_ids'])
        target_label = targets.uniq.first(5).join(', ')
        verification = pending['verification_status']
        line = "Pending mutation workflow: #{pending['tool']} (verification: #{verification})"
        line += " on #{target_label}" unless blank_string?(target_label)
        lines << line
        if Array(pending['verify_with']).any?
          lines << "Verify with: #{Array(pending['verify_with']).join(', ')} before claiming completion."
        end
      end

      issue_ids = Array(@state.dig('resolved_entities', 'issue_ids')).first(5)
      lines << "Recent issue IDs: #{issue_ids.map { |id| "##{id}" }.join(', ')}" if issue_ids.any?

      unless blank_string?(active_workspace_file)
        lines << "Recent workspace file: #{active_workspace_file}"
      end

      unless blank_string?(active_sheet_name)
        lines << "Recent sheet: #{active_sheet_name}"
      end

      lines.join("\n")
    end

    def last_read_tool_name
      @state.dig('last_read_evidence', 'tool').to_s
    end

    def last_read_result
      hash_or_empty(@state['last_read_evidence'])
    end

    def recent_child_scope_read?
      %w[issue_children_summary issue_schedule_tree].include?(last_read_tool_name)
    end

    def recent_parent_issue_read?
      evidence = last_read_result
      return false if evidence.empty?
      return false unless last_read_tool_name == 'issue_get'

      result = hash_or_empty(evidence['result'])
      result['children_count'].to_i.positive?
    end

    def verification_pending_message
      pending = pending_mutation
      return nil unless pending_verification? && pending

      tool = pending['tool']
      verify_with = Array(pending['verify_with'])
      targets = first_present_array(
        pending['target_issue_ids'],
        pending['target_version_ids'],
        pending['target_project_ids'],
        pending['target_user_ids']
      )

      target_text = Array(targets).first(5).join(', ')
      parts = ["앞선 변경 #{tool}의 read-back 검증이 아직 끝나지 않았습니다."]
      parts << "대상: #{target_text}" unless blank_string?(target_text)
      parts << "다음 조회 도구로 검증하세요: #{verify_with.join(', ')}." if verify_with.any?
      parts.join(' ')
    end

    def record_tool_result(tool_name, tool_input, result)
      metadata = self.class.metadata_for(tool_name)
      normalized_input = stringify(tool_input)
      normalized_result = stringify(result)

      remember_workspace_context!(tool_name, normalized_input, normalized_result)
      remember_entities!(tool_name, normalized_input, normalized_result)

      if tool_error_result?(normalized_result)
        return record_failed_execution(tool_name, normalized_input, normalized_result, metadata)
      end

      if metadata[:side_effecting]
        record_write_execution(tool_name, normalized_input, normalized_result, metadata)
      elsif metadata[:read_only]
        record_read_execution(tool_name, normalized_input, normalized_result, metadata)
      end
    end

    private

    def self.inferred_metadata_for(tool_name)
      read_only = READ_ONLY_PATTERNS.any? { |pattern| pattern.match?(tool_name) }
      side_effecting = !read_only && (tool_name == 'spreadsheet_export_report' || tool_name.match?(/(?:create|update|delete|add_member|remove_member|apply)\z/))
      entity_type =
        if tool_name.start_with?('issue_') || tool_name == 'insert_bulk_update'
          'issue'
        elsif tool_name.start_with?('version_')
          'version'
        elsif tool_name.start_with?('project_')
          'project'
        elsif tool_name.start_with?('user_')
          'user'
        elsif tool_name.start_with?('spreadsheet_')
          'spreadsheet'
        else
          'generic'
        end

      verify_with =
        if tool_name.end_with?('_update') || tool_name.end_with?('_create')
          ["#{entity_type}_get"]
        else
          []
        end

      {
        read_only: read_only,
        side_effecting: side_effecting,
        idempotent: read_only,
        confirm_required: tool_name.end_with?('_delete'),
        verify_with: verify_with,
        verification_required: side_effecting && verify_with.any?,
        entity_type: entity_type
      }
    end

    def normalize_state(state)
      raw = stringify(state || {})
      {
        'status' => normalize_status(raw['status']),
        'intent' => hash_or_empty(raw['intent']),
        'pending_mutation' => normalize_pending_mutation(raw['pending_mutation']),
        'resolved_entities' => normalize_resolved_entities(raw['resolved_entities']),
        'last_read_evidence' => hash_or_empty(raw['last_read_evidence']),
        'last_write_attempt' => hash_or_empty(raw['last_write_attempt']),
        'last_verification' => hash_or_empty(raw['last_verification']),
        'active_workspace_file' => string_or_nil(raw['active_workspace_file']),
        'active_sheet_name' => string_or_nil(raw['active_sheet_name'])
      }
    end

    def normalize_status(value)
      candidate = value.to_s
      STATUS_VALUES.include?(candidate) ? candidate : 'idle'
    end

    def normalize_pending_mutation(value)
      hash = hash_or_empty(value)
      return {} if hash.empty?

      hash['verify_with'] = Array(hash['verify_with']).map(&:to_s).uniq
      %w[target_issue_ids target_version_ids target_project_ids target_user_ids verified_issue_ids].each do |key|
        hash[key] = normalize_integer_array(hash[key])
      end
      hash['requested_changes'] = hash_or_empty(hash['requested_changes'])
      verification_status = hash['verification_status'].to_s
      hash['verification_status'] = blank_string?(verification_status) ? 'pending' : verification_status
      hash['verification_required'] = !!hash['verification_required']
      hash
    end

    def normalize_resolved_entities(value)
      raw = hash_or_empty(value)
      {
        'issue_ids' => normalize_integer_array(raw['issue_ids']),
        'version_ids' => normalize_integer_array(raw['version_ids']),
        'project_ids' => normalize_integer_array(raw['project_ids']),
        'user_ids' => normalize_integer_array(raw['user_ids']),
        'relation_ids' => normalize_integer_array(raw['relation_ids']),
        'file_names' => normalize_string_array(raw['file_names']),
        'sheet_names' => normalize_string_array(raw['sheet_names'])
      }
    end

    def record_failed_execution(tool_name, tool_input, result, metadata)
      if metadata[:side_effecting]
        @state['status'] = 'failed'
        @state['pending_mutation'] = {}
        @state['last_write_attempt'] = {
          'tool' => tool_name.to_s,
          'inputs' => deep_dup(tool_input),
          'status' => 'failed',
          'result' => summarize_result(result)
        }
        return "변경 도구 #{tool_name} 실행이 실패했습니다. 성공으로 보고하지 말고 오류를 설명하거나 필요한 조회 후 다시 시도하세요."
      end

      if pending_verification? && verify_with_tools.include?(tool_name.to_s)
        @state['last_verification'] = {
          'tool' => tool_name.to_s,
          'status' => 'tool_error',
          'result' => summarize_result(result)
        }
        return "검증 조회 #{tool_name}가 실패했습니다. 검증이 끝나지 않았으니 완료로 보고하지 마세요."
      end

      nil
    end

    def record_write_execution(tool_name, tool_input, result, metadata)
      requested_changes = requested_changes_for(tool_name, tool_input, result)
      mutation_state = {
        'tool' => tool_name.to_s,
        'entity_type' => metadata[:entity_type],
        'inputs' => deep_dup(tool_input),
        'requested_changes' => requested_changes,
        'verify_with' => Array(metadata[:verify_with]).map(&:to_s).uniq,
        'verification_required' => metadata[:verification_required],
        'verification_status' => metadata[:verification_required] ? 'pending' : 'passed',
        'target_issue_ids' => extract_issue_ids(tool_name, tool_input, result),
        'target_version_ids' => extract_version_ids(tool_name, tool_input, result),
        'target_project_ids' => extract_project_ids(tool_name, tool_input, result),
        'target_user_ids' => extract_user_ids(tool_name, tool_input, result),
        'relation_ids' => extract_relation_ids(tool_name, tool_input, result),
        'verified_issue_ids' => [],
        'required_sample_size' => required_sample_size_for(tool_name, tool_input, result),
        'result' => summarize_result(result)
      }

      @state['last_write_attempt'] = {
        'tool' => tool_name.to_s,
        'inputs' => deep_dup(tool_input),
        'requested_changes' => deep_dup(requested_changes),
        'status' => metadata[:verification_required] ? 'verification_pending' : 'succeeded',
        'result' => summarize_result(result)
      }

      if metadata[:verification_required]
        @state['pending_mutation'] = mutation_state
        @state['status'] = 'write_executed'
        verify_tools = Array(metadata[:verify_with]).join(', ')
        "변경 도구 #{tool_name} 실행이 성공했습니다. 완료로 보고하기 전에 #{verify_tools}로 read-back 검증이 필요합니다."
      else
        @state['pending_mutation'] = {}
        @state['last_verification'] = {
          'tool' => tool_name.to_s,
          'status' => 'not_required'
        }
        @state['status'] = 'verify_succeeded'
        nil
      end
    end

    def record_read_execution(tool_name, tool_input, result, metadata)
      @state['last_read_evidence'] = {
        'tool' => tool_name.to_s,
        'inputs' => deep_dup(tool_input),
        'result' => summarize_result(result)
      }

      if %w[idle intent_detected].include?(@state['status']) && target_entities_present?
        @state['status'] = 'target_resolved'
      elsif %w[intent_detected target_resolved].include?(@state['status']) && change_resolution_tool?(tool_name)
        @state['status'] = 'change_resolved'
      end

      if pending_verification? && Array(metadata[:verify_with]).empty? && verify_with_tools.include?(tool_name.to_s)
        metadata = metadata.merge(verify_with: verify_with_tools)
      end

      return nil unless pending_verification? && verify_with_tools.include?(tool_name.to_s)

      decision = verify_pending_mutation(tool_name, tool_input, result)
      return nil unless decision[:matched]

      @state['last_verification'] = {
        'tool' => tool_name.to_s,
        'status' => decision[:status],
        'checked_entities' => decision[:checked_entities],
        'mismatches' => decision[:mismatches]
      }.compact

      case decision[:status]
      when 'passed'
        @state['status'] = 'verify_succeeded'
        @state['pending_mutation'] = {}
      when 'failed'
        @state['status'] = 'failed'
        @state['pending_mutation']['verification_status'] = 'failed'
      when 'pending'
        @state['pending_mutation']['verification_status'] = 'pending'
      end

      decision[:message]
    end

    def verify_pending_mutation(tool_name, tool_input, result)
      pending = pending_mutation
      return { matched: false } unless pending

      case pending['tool']
      when 'issue_update', 'issue_create'
        verify_single_issue_readback(tool_name, result, pending)
      when 'insert_bulk_update'
        verify_bulk_issue_readback(tool_name, result, pending)
      when 'issue_auto_schedule_apply'
        verify_auto_schedule_apply_readback(tool_name, result, pending)
      when 'issue_relation_create', 'issue_relation_delete'
        verify_relation_readback(tool_name, result, pending)
      else
        verify_generic_readback(tool_name, result, pending)
      end
    end

    def verify_single_issue_readback(tool_name, result, pending)
      target_id = Array(pending['target_issue_ids']).first
      issue = extract_issue_from_read_result(tool_name, result, target_id)
      return { matched: false } unless issue

      mismatches = compare_issue_changes(issue, pending['requested_changes'])
      if mismatches.empty?
        {
          matched: true,
          status: 'passed',
          checked_entities: [target_id].compact,
          message: "read-back 검증이 통과했습니다. #{pending['tool']} 변경이 확인되었습니다."
        }
      else
        {
          matched: true,
          status: 'failed',
          checked_entities: [target_id].compact,
          mismatches: mismatches,
          message: "read-back 검증에서 요청한 변경과 실제 상태가 일치하지 않았습니다: #{mismatches.join(', ')}."
        }
      end
    end

    def verify_bulk_issue_readback(tool_name, result, pending)
      issues = extract_issue_rows_from_read_result(tool_name, result)
      target_ids = Array(pending['target_issue_ids'])
      matches = issues.select { |issue| target_ids.include?(integer_or_nil(issue['id'])) }
      return { matched: false } if matches.empty?

      verified_ids = Array(pending['verified_issue_ids'])
      mismatches = []
      newly_verified = []

      matches.each do |issue|
        issue_id = integer_or_nil(issue['id'])
        comparison = compare_issue_changes(issue, pending['requested_changes'])
        if comparison.empty?
          newly_verified << issue_id if issue_id
        else
          mismatches << "##{issue_id}: #{comparison.join(', ')}"
        end
      end

      return {
        matched: true,
        status: 'failed',
        checked_entities: matches.map { |issue| integer_or_nil(issue['id']) }.compact,
        mismatches: mismatches,
        message: "일괄 변경 검증에서 불일치가 발견되었습니다: #{mismatches.join(' | ')}."
      } if mismatches.any?

      verified_ids = (verified_ids + newly_verified).compact.uniq
      @state['pending_mutation']['verified_issue_ids'] = verified_ids

      required_count = [pending['required_sample_size'].to_i, 1].max
      if verified_ids.size >= required_count
        {
          matched: true,
          status: 'passed',
          checked_entities: verified_ids,
          message: "일괄 변경의 표본 검증이 통과했습니다. 확인된 이슈: #{verified_ids.map { |id| "##{id}" }.join(', ')}."
        }
      else
        {
          matched: true,
          status: 'pending',
          checked_entities: verified_ids,
          message: "일괄 변경 검증 진행 중입니다. 표본 #{verified_ids.size}/#{required_count}건을 확인했습니다."
        }
      end
    end

    def verify_auto_schedule_apply_readback(tool_name, result, pending)
      expected_rows = Array(pending.dig('requested_changes', 'scheduled_dates')).map { |row| stringify(row) }
      expected_by_id = expected_rows.each_with_object({}) do |row, memo|
        issue_id = integer_or_nil(row['id'])
        memo[issue_id] = row if issue_id
      end
      return { matched: false } if expected_by_id.empty?

      actual_rows = extract_auto_schedule_rows_from_read_result(tool_name, result)
      matches = actual_rows.select { |row| expected_by_id.key?(integer_or_nil(row['id'])) }
      return { matched: false } if matches.empty?

      verified_ids = Array(pending['verified_issue_ids'])
      mismatches = []
      newly_verified = []

      matches.each do |row|
        issue_id = integer_or_nil(row['id'])
        expected = expected_by_id[issue_id]
        next unless issue_id && expected

        issue_mismatches = []
        issue_mismatches << 'start_date' unless comparable_values?(expected['start_date'], row['start_date'])
        issue_mismatches << 'due_date' unless comparable_values?(expected['due_date'], row['due_date'])

        if issue_mismatches.empty?
          newly_verified << issue_id
        else
          mismatches << "##{issue_id}: #{issue_mismatches.join(', ')}"
        end
      end

      return {
        matched: true,
        status: 'failed',
        checked_entities: matches.map { |row| integer_or_nil(row['id']) }.compact,
        mismatches: mismatches,
        message: "자동 일정 적용 검증에서 불일치가 발견되었습니다: #{mismatches.join(' | ')}."
      } if mismatches.any?

      verified_ids = (verified_ids + newly_verified).compact.uniq
      @state['pending_mutation']['verified_issue_ids'] = verified_ids

      required_count = [pending['required_sample_size'].to_i, 1].max
      if verified_ids.size >= required_count
        {
          matched: true,
          status: 'passed',
          checked_entities: verified_ids,
          message: "자동 일정 적용 read-back 검증이 통과했습니다. 확인된 이슈: #{verified_ids.map { |id| "##{id}" }.join(', ')}."
        }
      else
        {
          matched: true,
          status: 'pending',
          checked_entities: verified_ids,
          message: "자동 일정 적용 검증 진행 중입니다. 표본 #{verified_ids.size}/#{required_count}건을 확인했습니다."
        }
      end
    end

    def verify_relation_readback(tool_name, result, pending)
      relations = extract_relations_from_read_result(tool_name, result)
      return { matched: false } if relations.empty?

      related_issue_id = integer_or_nil(pending.dig('inputs', 'related_issue_id')) ||
                         integer_or_nil(pending.dig('result', 'relation', 'other_issue_id'))
      relation_type = pending.dig('requested_changes', 'relation_type').to_s

      relation_exists = relations.any? do |relation|
        integer_or_nil(dig_value(relation, %w[other_issue id])) == related_issue_id &&
          relation['relation_type'].to_s == relation_type
      end

      if pending['tool'] == 'issue_relation_create'
        if relation_exists
          {
            matched: true,
            status: 'passed',
            checked_entities: Array(pending['target_issue_ids']),
            message: '관계 생성 read-back 검증이 통과했습니다.'
          }
        else
          {
            matched: true,
            status: 'failed',
            checked_entities: Array(pending['target_issue_ids']),
            mismatches: ['requested relation missing'],
            message: '관계 생성 후 read-back에서 요청한 관계가 확인되지 않았습니다.'
          }
        end
      elsif relation_exists
        {
          matched: true,
          status: 'failed',
          checked_entities: Array(pending['target_issue_ids']),
          mismatches: ['deleted relation still present'],
          message: '관계 삭제 후 read-back에서 관계가 아직 남아 있습니다.'
        }
      else
        {
          matched: true,
          status: 'passed',
          checked_entities: Array(pending['target_issue_ids']),
          message: '관계 삭제 read-back 검증이 통과했습니다.'
        }
      end
    end

    def verify_generic_readback(tool_name, result, pending)
      entity = extract_generic_entity(tool_name, result)
      return { matched: false } unless entity

      mismatches = compare_generic_changes(entity, pending['requested_changes'])
      if mismatches.empty?
        {
          matched: true,
          status: 'passed',
          message: "read-back 검증이 통과했습니다. #{pending['tool']} 변경이 확인되었습니다."
        }
      else
        {
          matched: true,
          status: 'failed',
          mismatches: mismatches,
          message: "read-back 검증에서 요청한 변경과 실제 상태가 일치하지 않았습니다: #{mismatches.join(', ')}."
        }
      end
    end

    def requested_changes_for(tool_name, tool_input, result)
      changes = {}
      tool_input.each do |field, value|
        next if REQUESTED_CHANGE_IGNORED_FIELDS.include?(field.to_s)
        next if identity_field?(tool_name, field.to_s)

        changes[field.to_s] = deep_dup(value)
      end

      if tool_name.to_s == 'issue_relation_delete'
        relation = hash_or_empty(result['relation'])
        changes['relation_type'] = relation['relation_type'] if relation.key?('relation_type')
      end

      if tool_name.to_s == 'issue_auto_schedule_apply'
        scheduled_dates = Array(result['issues']).filter_map do |issue|
          row = stringify(issue)
          issue_id = integer_or_nil(row['id'])
          next unless issue_id

          {
            'id' => issue_id,
            'start_date' => string_or_nil(row['start_date']),
            'due_date' => string_or_nil(row['due_date'])
          }
        end
        changes['scheduled_dates'] = scheduled_dates if scheduled_dates.any?
      end

      changes
    end

    def required_sample_size_for(tool_name, tool_input, result)
      if tool_name.to_s == 'insert_bulk_update'
        issue_ids = extract_issue_ids(tool_name, tool_input, result)
        return [issue_ids.size, 3].min
      end

      if tool_name.to_s == 'issue_auto_schedule_apply'
        issue_ids = extract_issue_ids(tool_name, tool_input, result)
        return [issue_ids.size, 5].min
      end

      0
    end

    def compare_issue_changes(issue, requested_changes)
      compare_changes(issue, requested_changes) do |field|
        ISSUE_FIELD_READERS[field.to_s]
      end
    end

    def compare_generic_changes(entity, requested_changes)
      compare_changes(entity, requested_changes) do |field|
        [field.to_s]
      end
    end

    def compare_changes(entity, requested_changes)
      mismatches = []

      requested_changes.each do |field, expected|
        next if field.to_s == 'notes'

        if field.to_s == 'custom_fields'
          custom_field_mismatches = compare_custom_fields(entity, expected)
          mismatches.concat(custom_field_mismatches) if custom_field_mismatches.any?
          next
        end

        reader_paths = Array(yield(field))
        actual = read_candidate_value(entity, reader_paths)
        next if comparable_values?(expected, actual)

        mismatches << field.to_s
      end

      mismatches
    end

    def compare_custom_fields(entity, expected_fields)
      actual_fields = Array(entity['custom_fields']).map { |field| stringify(field) }
      mismatches = []

      Array(expected_fields).each do |item|
        normalized = stringify(item)
        field_id = integer_or_nil(normalized['id'])
        expected_value = normalized['value']
        actual = actual_fields.find { |field| integer_or_nil(field['id']) == field_id }
        actual_value = actual ? actual['value'] : nil
        mismatches << "custom_field_#{field_id}" unless comparable_values?(expected_value, actual_value)
      end

      mismatches
    end

    def read_candidate_value(entity, reader_paths)
      Array(reader_paths).each do |path|
        value = dig_value(entity, Array(path))
        return value unless value.nil?
      end
      nil
    end

    def comparable_values?(expected, actual)
      if expected.is_a?(Array) || actual.is_a?(Array)
        Array(expected).map { |item| stringify(item) }.sort_by(&:to_s) ==
          Array(actual).map { |item| stringify(item) }.sort_by(&:to_s)
      elsif expected.nil?
        actual.nil?
      elsif expected.is_a?(Numeric)
        case actual
        when Numeric
          actual.to_f == expected.to_f
        when String
          stripped = actual.strip
          return false unless stripped.match?(/\A-?\d+(?:\.\d+)?\z/)

          stripped.to_f == expected.to_f
        else
          false
        end
      else
        actual.to_s == expected.to_s
      end
    end

    def extract_issue_from_read_result(tool_name, result, target_id)
      return stringify(result) if tool_name.to_s == 'issue_get' && integer_or_nil(result['id']) == target_id

      extract_issue_rows_from_read_result(tool_name, result)
        .find { |issue| integer_or_nil(issue['id']) == target_id }
    end

    def extract_issue_rows_from_read_result(tool_name, result)
      if tool_name.to_s == 'issue_get'
        issues = Array(result['issues']).map { |issue| stringify(issue) }
        return issues if issues.any?

        return [stringify(result)]
      end

      Array(result['issues']).map { |issue| stringify(issue) }
    end

    def extract_auto_schedule_rows_from_read_result(tool_name, result)
      case tool_name.to_s
      when 'issue_get'
        extract_issue_rows_from_read_result(tool_name, result)
      when 'issue_schedule_tree'
        trees = if result['trees'].is_a?(Array)
                  Array(result['trees']).map { |tree| stringify(tree) }
                else
                  [stringify(result)]
                end
        trees.flat_map do |tree|
          Array(tree['children']).map { |issue| stringify(issue) }
        end
      else
        []
      end
    end

    def extract_relations_from_read_result(tool_name, result)
      case tool_name.to_s
      when 'issue_relations_get'
        Array(result['relations']).map { |relation| stringify(relation) }
      when 'issue_get'
        Array(result['relations']).map { |relation| stringify(relation) }
      else
        []
      end
    end

    def extract_generic_entity(tool_name, result)
      case tool_name.to_s
      when /_get\z/
        stringify(result)
      else
        nil
      end
    end

    def remember_workspace_context!(tool_name, tool_input, result)
      file_name = result['file_name'] || tool_input['file_name']
      @state['active_workspace_file'] = file_name.to_s unless blank_string?(file_name)

      sheet_name = result['sheet_name'] || tool_input['sheet_name']
      @state['active_sheet_name'] = sheet_name.to_s unless blank_string?(sheet_name)

      if tool_name.to_s == 'spreadsheet_list_uploads'
        files = Array(result['files']).map { |file| stringify(file)['stored_name'] }.compact
        merge_string_array!(@state.dig('resolved_entities', 'file_names'), files)
        if blank_string?(@state['active_workspace_file']) && files.size == 1
          @state['active_workspace_file'] = files.first
        end
      end

      if tool_name.to_s == 'spreadsheet_list_sheets'
        sheet_names = Array(result['sheets']).map { |sheet| stringify(sheet)['name'] }.compact
        merge_string_array!(@state.dig('resolved_entities', 'sheet_names'), sheet_names)
      end
    end

    def remember_entities!(tool_name, tool_input, result)
      merge_integer_array!(@state.dig('resolved_entities', 'issue_ids'), extract_issue_ids(tool_name, tool_input, result))
      merge_integer_array!(@state.dig('resolved_entities', 'version_ids'), extract_version_ids(tool_name, tool_input, result))
      merge_integer_array!(@state.dig('resolved_entities', 'project_ids'), extract_project_ids(tool_name, tool_input, result))
      merge_integer_array!(@state.dig('resolved_entities', 'user_ids'), extract_user_ids(tool_name, tool_input, result))
      merge_integer_array!(@state.dig('resolved_entities', 'relation_ids'), extract_relation_ids(tool_name, tool_input, result))
      merge_string_array!(@state.dig('resolved_entities', 'file_names'), extract_file_names(tool_name, tool_input, result))
      merge_string_array!(@state.dig('resolved_entities', 'sheet_names'), extract_sheet_names(tool_name, tool_input, result))
    end

    def extract_issue_ids(tool_name, tool_input, result)
      values = []
      values.concat extract_integers(tool_input['issue_ids'])
      values.concat extract_integers(tool_input['ids'])
      values << integer_or_nil(tool_input['id']) if tool_name.to_s.start_with?('issue_')
      values << integer_or_nil(tool_input['issue_id'])
      values << integer_or_nil(tool_input['related_issue_id'])
      values << integer_or_nil(tool_input['parent_id'])
      values.concat extract_integers(tool_input['parent_ids'])
      values << integer_or_nil(tool_input['parent_issue_id'])
      values << integer_or_nil(result['id']) if tool_name.to_s.start_with?('issue_')
      values.concat extract_integers(result['issue_ids'])
      values.concat extract_integers(result['updated_issue_ids'])
      values.concat extract_integers(result['requested_issue_ids'])
      values.concat extract_integers(result['missing_estimated_hours_issue_ids'])
      values.concat Array(result['issues']).map { |issue| integer_or_nil(stringify(issue)['id']) }
      values.concat Array(result['children']).map { |issue| integer_or_nil(stringify(issue)['id']) }
      values.concat Array(result['scheduled_issues']).map { |issue| integer_or_nil(stringify(issue)['id']) }
      values.concat Array(result['trees']).flat_map { |tree| Array(stringify(tree)['children']) }.map { |issue| integer_or_nil(stringify(issue)['id']) }
      values.compact.uniq
    end

    def extract_version_ids(_tool_name, tool_input, result)
      values = []
      values << integer_or_nil(tool_input['version_id'])
      values << integer_or_nil(tool_input['fixed_version_id'])
      values << integer_or_nil(result['version_id'])
      values << integer_or_nil(dig_value(result, %w[version id]))
      values << integer_or_nil(dig_value(result, %w[fixed_version id]))
      values.compact.uniq
    end

    def extract_project_ids(_tool_name, tool_input, result)
      values = []
      values << integer_or_nil(tool_input['project_id'])
      values << integer_or_nil(result['project_id'])
      values << integer_or_nil(dig_value(result, %w[project id]))
      values.compact.uniq
    end

    def extract_user_ids(_tool_name, tool_input, result)
      values = []
      values << integer_or_nil(tool_input['user_id'])
      values << integer_or_nil(tool_input['assigned_to_id'])
      values << integer_or_nil(result['user_id'])
      values << integer_or_nil(dig_value(result, %w[user id]))
      values << integer_or_nil(dig_value(result, %w[assigned_to id]))
      values.compact.uniq
    end

    def extract_relation_ids(tool_name, tool_input, result)
      values = []
      values << integer_or_nil(tool_input['id']) if tool_name.to_s.include?('relation')
      values << integer_or_nil(result['id']) if tool_name.to_s.include?('relation')
      values << integer_or_nil(dig_value(result, %w[relation id]))
      values.compact.uniq
    end

    def extract_file_names(_tool_name, tool_input, result)
      values = []
      values << tool_input['file_name']
      values << result['file_name']
      values.concat Array(result['files']).map { |file| stringify(file)['stored_name'] }
      values.compact.map(&:to_s).reject { |value| blank_string?(value) }.uniq
    end

    def extract_sheet_names(_tool_name, tool_input, result)
      values = []
      values << tool_input['sheet_name']
      values << result['sheet_name']
      values.concat Array(result['sheets']).map { |sheet| stringify(sheet)['name'] }
      values.compact.map(&:to_s).reject { |value| blank_string?(value) }.uniq
    end

    def target_entities_present?
      %w[issue_ids version_ids project_ids user_ids relation_ids].any? do |key|
        Array(@state.dig('resolved_entities', key)).any?
      end
    end

    def change_resolution_tool?(tool_name)
      tool_name.to_s.start_with?('enum_') ||
        %w[user_list user_get version_list version_get project_list project_get spreadsheet_extract_rows].include?(tool_name.to_s)
    end

    def identity_field?(tool_name, field_name)
      return true if %w[id issue_id issue_ids relation_id].include?(field_name)
      return true if field_name == 'preview_token'
      return true if field_name == 'project_id' && tool_name.to_s.start_with?('project_')
      return true if field_name == 'user_id' && tool_name.to_s.start_with?('user_')
      return true if field_name == 'version_id' && tool_name.to_s.start_with?('version_')

      false
    end

    def summarize_result(result)
      return result unless result.is_a?(Hash)

      summary = {}
      %w[id success message error updated_count failed_count file_name download_path].each do |key|
        summary[key] = deep_dup(result[key]) if result.key?(key)
      end

      if result['children'].is_a?(Array)
        summary['children_count'] = result['children'].size
        summary['child_ids'] = Array(result['children']).first(5).map { |issue| integer_or_nil(stringify(issue)['id']) }.compact
      end

      if result['children_by_stage'].is_a?(Hash)
        summary['children_count'] = result['children_by_stage'].values.sum { |children| Array(children).size }
      end

      if result['relation'].is_a?(Hash)
        relation = stringify(result['relation'])
        summary['relation'] = {
          'id' => relation['id'],
          'relation_type' => relation['relation_type'],
          'other_issue_id' => dig_value(relation, %w[other_issue id])
        }.compact
      end

      summary
    end

    def tool_error_result?(result)
      result.is_a?(Hash) && result.key?('error')
    end

    def hash_or_nil(value)
      hash = hash_or_empty(value)
      hash.empty? ? nil : hash
    end

    def hash_or_empty(value)
      value.is_a?(Hash) ? stringify(value) : {}
    end

    def normalize_integer_array(value)
      extract_integers(value).uniq
    end

    def normalize_string_array(value)
      Array(value).map(&:to_s).reject { |item| blank_string?(item) }.uniq
    end

    def merge_integer_array!(target, values)
      target.concat(Array(values).filter_map { |value| integer_or_nil(value) })
      target.uniq!
    end

    def merge_string_array!(target, values)
      target.concat(Array(values).map(&:to_s).reject { |value| blank_string?(value) })
      target.uniq!
    end

    def extract_integers(values)
      Array(values).filter_map { |value| integer_or_nil(value) }
    end

    def integer_or_nil(value)
      return nil if value.nil?
      return value if value.is_a?(Integer)

      string = value.to_s.strip
      return nil if string.empty?
      return nil unless string.match?(/\A-?\d+\z/)

      string.to_i
    end

    def string_or_nil(value)
      string = value.to_s
      blank_string?(string) ? nil : string
    end

    def blank_string?(value)
      value.to_s.strip.empty?
    end

    def first_present_array(*values)
      values.each do |value|
        array = Array(value)
        return array if array.any?
      end
      []
    end

    def dig_value(object, path)
      current = stringify(object)
      Array(path).each do |key|
        return nil unless current.is_a?(Hash)

        current = current[key.to_s]
      end
      current
    end

    def stringify(object)
      case object
      when Hash
        object.each_with_object({}) do |(key, value), memo|
          memo[key.to_s] = stringify(value)
        end
      when Array
        object.map { |value| stringify(value) }
      else
        object
      end
    end

    def deep_dup(object)
      case object
      when Hash
        object.each_with_object({}) { |(key, value), memo| memo[key] = deep_dup(value) }
      when Array
        object.map { |value| deep_dup(value) }
      else
        object
      end
    end
  end
end
