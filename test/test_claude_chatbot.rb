require File.expand_path('support/chatbot_unit_helper', __dir__)

class ClaudeChatbotTest < ActiveSupport::TestCase
  def build_chatbot
    RedmineTxMcp::ClaudeChatbot.new(
      provider: 'openai',
      endpoint_url: 'http://example.test/v1/chat/completions',
      model: 'test-model'
    )
  end

  test "issue search queries still keep update tools available for follow-up actions" do
    chatbot = build_chatbot

    chatbot.send(:select_tools_for_query, '이슈 상태 알려줘')
    tool_names = chatbot.send(:available_mcp_tools).map { |tool| tool[:name] }

    assert_includes tool_names, 'issue_get'
    assert_includes tool_names, 'issue_update'
    assert_includes tool_names, 'insert_bulk_update'
    assert_includes tool_names, 'enum_statuses'
  end

  test "assignment requests include both user lookup and update tools" do
    chatbot = build_chatbot

    chatbot.send(:select_tools_for_query, '123번 이슈를 홍길동에게 할당해줘')
    tool_names = chatbot.send(:available_mcp_tools).map { |tool| tool[:name] }

    assert_includes tool_names, 'issue_update'
    assert_includes tool_names, 'user_list'
    assert_includes tool_names, 'user_get'
  end

  test "relation queries expose relation inspection tools" do
    chatbot = build_chatbot

    chatbot.send(:select_tools_for_query, '123번 이슈의 선행 이슈와 후행 이슈를 알려줘')
    tool_names = chatbot.send(:available_mcp_tools).map { |tool| tool[:name] }

    assert_includes tool_names, 'issue_list'
    assert_includes tool_names, 'issue_get'
    assert_includes tool_names, 'issue_relations_get'
  end

  test "build_execution_plan returns korean plan for modification requests" do
    chatbot = build_chatbot

    plan = chatbot.send(:build_execution_plan, '이슈 123 상태를 QA로 변경해줘')

    assert_not_nil plan
    assert_equal '계획', plan[:title]
    assert_equal 3, plan[:steps].size
    assert_match(/#123/, plan[:steps].first)
    assert_match(/QA|상태/, plan[:steps][1])
    assert_match(/수정/, plan[:steps].last)
  end

  test "build_execution_plan prefers bulk tool for bulk modification requests" do
    chatbot = build_chatbot

    plan = chatbot.send(:build_execution_plan, '이슈 101번, 102번, 103번을 모두 QA로 변경해줘')

    assert_not_nil plan
    assert_match(/insert_bulk_update/, plan[:steps].last)
  end

  test "build_execution_plan returns english plan for english request" do
    chatbot = build_chatbot

    plan = chatbot.send(:build_execution_plan, 'Update issue 123 and move it to QA')

    assert_not_nil plan
    assert_equal 'Plan', plan[:title]
    assert_equal 3, plan[:steps].size
    assert_match(/Identify the target issue/, plan[:steps].first)
  end

  test "build_execution_plan separates issue_list and issue_get for relation queries" do
    chatbot = build_chatbot

    plan = chatbot.send(:build_execution_plan, '로그인 이슈를 찾아서 선행 관계를 알려줘')

    assert_not_nil plan
    assert_match(/issue_list/, plan[:steps].first)
    assert_match(/로그인/, plan[:steps].first)
    assert_match(/선행/, plan[:steps][1])
    assert_match(/issue_get|issue_relations_get/, plan[:steps][1])
  end

  test "planner activates for multi-step analysis and exposes plan_update tool" do
    chatbot = build_chatbot

    chatbot.send(:select_tools_for_query, '버전 진행 상황 분석하고 지연 원인도 정리해줘')
    tool_names = chatbot.send(:available_mcp_tools).map { |tool| tool[:name] }

    assert_includes tool_names, 'plan_update'
    assert_includes tool_names, 'version_overview'
  end

  test "spreadsheet requests expose spreadsheet and issue mutation tools together" do
    chatbot = build_chatbot

    chatbot.send(:select_tools_for_query, '업로드한 report.xlsx 기준으로 이슈를 일괄 수정해줘')
    tool_names = chatbot.send(:available_mcp_tools).map { |tool| tool[:name] }

    assert_includes tool_names, 'spreadsheet_list_uploads'
    assert_includes tool_names, 'spreadsheet_extract_rows'
    assert_includes tool_names, 'spreadsheet_export_report'
    assert_includes tool_names, 'insert_bulk_update'
  end

  test "auto schedule requests expose preview and apply tools" do
    chatbot = build_chatbot

    chatbot.send(:select_tools_for_query, '부모 이슈 123의 하위 일감을 자동 일정 배치해줘')
    tool_names = chatbot.send(:available_mcp_tools).map { |tool| tool[:name] }

    assert_includes tool_names, 'issue_schedule_tree'
    assert_includes tool_names, 'issue_auto_schedule_preview'
    assert_includes tool_names, 'issue_auto_schedule_apply'
  end

  test "auto schedule requests produce auto schedule plan" do
    chatbot = build_chatbot

    plan = chatbot.send(:build_execution_plan, '부모 이슈 123의 하위 일감을 자동 일정 배치해줘')

    assert_not_nil plan
    assert_match(/issue_schedule_tree|issue_children_summary/, plan[:steps].first)
    assert_match(/issue_auto_schedule_preview/, plan[:steps][1])
    assert_match(/issue_auto_schedule_apply/, plan[:steps][2])
  end

  test "spreadsheet requests produce spreadsheet-aware plan" do
    chatbot = build_chatbot

    plan = chatbot.send(:build_execution_plan, 'report.xlsx 기준으로 미배정 이슈 상태를 바꾸고 결과 엑셀도 만들어줘')

    assert_not_nil plan
    assert_match(/report\.xlsx/, plan[:steps].first)
    assert_match(/미배정/, plan[:steps][1])
    assert_match(/spreadsheet_export_report/, plan[:steps].last)
  end

  test "issue search plans include search filters from the question" do
    chatbot = build_chatbot

    plan = chatbot.send(:build_execution_plan, '미배정 버그 이슈를 찾아서 원인을 정리해줘')

    assert_not_nil plan
    assert_match(/미배정/, plan[:steps].first)
    assert_match(/버그/, plan[:steps].first)
    assert_match(/근거|원인/, plan[:steps].last)
  end

  test "system message includes workspace uploads and reports when workspace context is set" do
    session_id = "spreadsheet-test-#{SecureRandom.hex(4)}"
    workspace = RedmineTxMcp::ChatbotWorkspace.new(user_id: 1, project_id: 1, session_id: session_id)
    workspace.save_report(file_name: 'result.xlsx', content: 'fake-xlsx')

    chatbot = build_chatbot
    chatbot.set_workspace_context(user_id: 1, project_id: 1, session_id: session_id)

    summary = chatbot.send(:workspace_context_summary)

    assert_match(/Current chatbot workspace/, summary)
    assert_match(/result\.xlsx/, summary)
  ensure
    workspace&.clear!
  end

  test "session state export and restore preserves structured tool history" do
    chatbot = build_chatbot
    chatbot.send(:add_to_conversation, 'user', '이슈 123 상태를 바꿔줘')
    chatbot.send(
      :add_to_conversation,
      'assistant',
      [{ 'type' => 'tool_use', 'id' => 'tool-1', 'name' => 'issue_get', 'input' => { 'id' => 123 } }]
    )
    chatbot.send(
      :add_to_conversation,
      'user',
      [{ 'type' => 'tool_result', 'tool_use_id' => 'tool-1', 'content' => '{"id":123}' }]
    )

    snapshot = chatbot.export_session_state
    restored = build_chatbot
    restored.restore_session_state(snapshot)

    history = restored.instance_variable_get(:@conversation_history)
    assert_equal 3, history.size
    assert_equal 'assistant', history[1][:role]
    assert_equal 'tool_use', history[1][:content].first['type']
    assert_equal 'tool_result', history[2][:content].first['type']
  end

  test "session state export and restore preserves pending plan context for ambiguous follow-up turns" do
    chatbot = build_chatbot
    chatbot.send(:select_tools_for_query, '이슈 123 상태를 QA로 변경해줘')
    chatbot.send(
      :execute_plan_update,
      {
        'steps' => [
          { 'title' => '이슈 조회', 'status' => 'completed' },
          { 'title' => '상태 변경', 'status' => 'in_progress' }
        ],
        'summary' => '상태 변경 진행 중'
      }
    )

    snapshot = chatbot.export_session_state
    restored = build_chatbot
    restored.restore_session_state(snapshot)
    restored.send(:reset_turn_state)
    restored.send(:reset_metrics)
    restored.send(:select_tools_for_query, '계속 진행해줘')

    assert_equal true, restored.send(:plan_pending?)
    assert_equal 'restored', restored.instance_variable_get(:@selection_confidence)

    tool_names = restored.send(:available_mcp_tools).map { |tool| tool[:name] }
    assert_includes tool_names, 'issue_update'
    assert_includes tool_names, 'issue_get'
  end

  test "plan_update stores normalized plan state and returns plan event payload" do
    chatbot = build_chatbot

    result = chatbot.send(
      :execute_plan_update,
      {
        'steps' => [
          { 'title' => '이슈 조회', 'status' => 'completed' },
          { 'title' => '상태 변경', 'status' => 'in_progress' }
        ],
        'summary' => '상태 변경 진행 중'
      }
    )

    assert_match(/계획 업데이트/, result[:content])
    assert_equal '실행 계획', result[:event][:title]
    assert_equal 2, result[:event][:steps].size
    assert_equal '상태 변경 진행 중', result[:event][:status]
  end

  test "repeat limits distinguish read and write tools" do
    chatbot = build_chatbot

    assert_equal 3, chatbot.send(:repeat_limit_for_tool, 'issue_get')
    assert_equal 1, chatbot.send(:repeat_limit_for_tool, 'issue_update')
    assert_equal 3, chatbot.send(:repeat_limit_for_tool, 'spreadsheet_extract_rows')
    assert_equal 1, chatbot.send(:repeat_limit_for_tool, 'spreadsheet_export_report')
  end

  test "bulk mutation requests expand tool loop budget" do
    chatbot = build_chatbot

    chatbot.send(:prepare_tool_call_budget, '이슈 101번, 102번, 103번을 모두 QA로 변경해줘')

    assert_operator chatbot.send(:max_tool_calls), :>=, 30
  end

  test "complex read analysis requests expand tool loop budget" do
    chatbot = build_chatbot

    chatbot.send(:prepare_tool_call_budget, '135316 일감의 하위 일감이 지금 추정시간이 없는데 과거 유사 일감을 고려해 추정시간을 제안해 줄래? 그근거도 같이 알려줘')

    assert_operator chatbot.send(:max_tool_calls), :>=, 22
  end

  test "simple issue lookups keep the baseline tool budget" do
    chatbot = build_chatbot

    chatbot.send(:prepare_tool_call_budget, '이슈 135316 상태 알려줘')

    assert_equal 15, chatbot.send(:max_tool_calls)
  end

  test "spreadsheet batch mutation requests reserve extra tool budget" do
    chatbot = build_chatbot

    chatbot.send(:prepare_tool_call_budget, 'report.xlsx 기준으로 이슈 101번, 102번, 103번, 104번을 한꺼번에 수정하고 결과 엑셀도 만들어줘')

    assert_operator chatbot.send(:max_tool_calls), :>=, 37
  end

  test "requested issue count handles korean particles on trailing ids" do
    chatbot = build_chatbot

    count = chatbot.send(:requested_issue_count, '이슈 101번, 102번, 103번, 104번을 한꺼번에 수정해줘')

    assert_equal 4, count
  end

  test "bulk mutation requests expose insert_bulk_update tool" do
    chatbot = build_chatbot

    chatbot.send(:select_tools_for_query, '이슈 101번, 102번, 103번을 모두 QA로 변경해줘')
    tool_names = chatbot.send(:available_mcp_tools).map { |tool| tool[:name] }

    assert_includes tool_names, 'insert_bulk_update'
  end

  test "budget_conversation_history prioritizes recent turns over the first question" do
    chatbot = build_chatbot
    messages = [
      { role: 'user', content: 'A' * 70_000 },
      { role: 'assistant', content: 'B' * 5_000 },
      { role: 'user', content: 'C' * 20_000 }
    ]

    result = chatbot.send(:budget_conversation_history, messages)

    assert_equal ['B' * 5_000, 'C' * 20_000], result.map { |msg| msg[:content] || msg['content'] }
  end

  test "write tools can retry after an error but stop after a success" do
    chatbot = build_chatbot
    input = { 'id' => 123, 'status_id' => 5 }

    chatbot.send(:record_tool_call!, 'issue_update', input, { 'error' => 'timeout' })
    assert_equal false, chatbot.send(:repeat_blocked?, 'issue_update', input)

    chatbot.send(:record_tool_call!, 'issue_update', input, { 'ok' => true })
    assert_equal true, chatbot.send(:repeat_blocked?, 'issue_update', input)
  end

  test "handle_tool_calls enforces actual tool budget within a single model response" do
    chatbot = build_chatbot
    chatbot.instance_variable_set(:@tool_call_budget, 1)

    response = {
      'content' => [
        { 'type' => 'tool_use', 'id' => 'tool-1', 'name' => 'issue_get', 'input' => { 'id' => 123 } },
        { 'type' => 'tool_use', 'id' => 'tool-2', 'name' => 'user_get', 'input' => { 'id' => 7 } }
      ]
    }

    executed_tools = []
    request_bodies = []

    chatbot.stub(:execute_mcp_tool, lambda { |tool_name, _tool_input|
      executed_tools << tool_name
      { 'ok' => true, 'tool' => tool_name }
    }) do
      chatbot.stub(:invoke_model, lambda { |request_body, thinking_message: nil, event_handler: nil|
        request_bodies << request_body
        { 'content' => [{ 'type' => 'text', 'text' => 'summary' }] }
      }) do
        result = chatbot.send(:handle_tool_calls, response)

        assert_equal ['issue_get'], executed_tools
        assert_equal 'summary', chatbot.send(:extract_text_content, result)
      end
    end

    assert_equal 1, chatbot.instance_variable_get(:@real_tool_calls)
    refute request_bodies.last.key?(:tools)

    last_history_entry = chatbot.instance_variable_get(:@conversation_history).last
    warning_result = last_history_entry[:content].last
    assert_match(/도구 호출 한도/, warning_result[:content])
  end

  test "handle_tool_calls defers write tools until read results are reviewed" do
    chatbot = build_chatbot

    response = {
      'content' => [
        { 'type' => 'tool_use', 'id' => 'tool-1', 'name' => 'issue_get', 'input' => { 'id' => 123 } },
        { 'type' => 'tool_use', 'id' => 'tool-2', 'name' => 'issue_update', 'input' => { 'id' => 123, 'status_id' => 5 } }
      ]
    }

    executed_tools = []
    request_bodies = []

    chatbot.stub(:execute_mcp_tool, lambda { |tool_name, _tool_input|
      executed_tools << tool_name
      { 'ok' => true, 'tool' => tool_name }
    }) do
      chatbot.stub(:invoke_model, lambda { |request_body, thinking_message: nil, event_handler: nil|
        request_bodies << request_body
        { 'content' => [{ 'type' => 'text', 'text' => 'next step' }] }
      }) do
        result = chatbot.send(:handle_tool_calls, response)

        assert_equal ['issue_get'], executed_tools
        assert_equal 'next step', chatbot.send(:extract_text_content, result)
      end
    end

    assert_equal 0, chatbot.instance_variable_get(:@write_tool_calls)
    assert request_bodies.last.key?(:tools)

    last_history_entry = chatbot.instance_variable_get(:@conversation_history).last
    deferred_result = last_history_entry[:content].last
    assert_match(/쓰기 도구 issue_update 실행을 보류했습니다/, deferred_result[:content])
  end

  test "handle_tool_calls executes only one write tool per response" do
    chatbot = build_chatbot

    response = {
      'content' => [
        { 'type' => 'tool_use', 'id' => 'tool-1', 'name' => 'issue_update', 'input' => { 'id' => 123, 'status_id' => 5 } },
        { 'type' => 'tool_use', 'id' => 'tool-2', 'name' => 'issue_relation_create', 'input' => { 'issue_id' => 123, 'issue_to_id' => 124, 'relation_type' => 'relates' } }
      ]
    }

    executed_tools = []

    chatbot.stub(:execute_mcp_tool, lambda { |tool_name, _tool_input|
      executed_tools << tool_name
      { 'ok' => true, 'tool' => tool_name }
    }) do
      chatbot.stub(:invoke_model, lambda { |request_body, thinking_message: nil, event_handler: nil|
        { 'content' => [{ 'type' => 'text', 'text' => 'next step' }] }
      }) do
        chatbot.send(:handle_tool_calls, response)
      end
    end

    assert_equal ['issue_update'], executed_tools

    last_history_entry = chatbot.instance_variable_get(:@conversation_history).last
    deferred_result = last_history_entry[:content].last
    assert_match(/한 단계에서 하나씩만 실행합니다/, deferred_result[:content])
  end

  test "guard retry still triggers capability retry after read-only tool usage" do
    chatbot = build_chatbot
    chatbot.instance_variable_set(:@real_tool_calls, 1)

    response = {
      'content' => [
        {
          'type' => 'text',
          'text' => '죄송합니다, 현재 수정 기능은 제공되지 않으며 조회만 가능합니다.'
        }
      ]
    }

    retry_info = chatbot.send(:guard_retry_instruction, response, '이슈 123 상태를 QA로 변경해줘')

    assert_not_nil retry_info
    assert_equal true, retry_info[:force_all_tools]
    assert_equal({ type: 'any' }, retry_info[:tool_choice])
  end

  test "guard retry treats failed write attempts as insufficient for completion claims" do
    chatbot = build_chatbot
    chatbot.instance_variable_set(:@real_tool_calls, 1)
    chatbot.instance_variable_set(:@write_tool_calls, 1)

    response = {
      'content' => [
        {
          'type' => 'text',
          'text' => '이슈 123 상태를 QA로 변경했습니다.'
        }
      ]
    }

    retry_info = chatbot.send(:guard_retry_instruction, response, '이슈 123 상태를 QA로 변경해줘')

    assert_not_nil retry_info
    assert_equal true, retry_info[:force_all_tools]
    assert_match(/성공 결과/, retry_info[:instruction])
  end

  test "guard retry instruction forces tool retry after capability refusal" do
    chatbot = build_chatbot
    chatbot.send(:select_tools_for_query, '이슈 123 상태를 QA로 변경해줘')

    response = {
      'content' => [
        {
          'type' => 'text',
          'text' => '죄송합니다, 현재 제가 접근할 수 있는 도구는 조회(issue_get, issue_list) 기능만 있으며, 이슈 수정(update) 기능은 제공되지 않습니다.'
        }
      ]
    }

    retry_info = chatbot.send(:guard_retry_instruction, response, '이슈 123 상태를 QA로 변경해줘')

    assert_not_nil retry_info
    assert_equal true, retry_info[:force_all_tools]
    assert_equal({ type: 'any' }, retry_info[:tool_choice])
  end

  test "chatbot run guard returns timeout stop signal" do
    ticks = [0.0, 1.3]
    guard = RedmineTxMcp::ChatbotRunGuard.new(
      max_iterations: 3,
      max_elapsed_seconds: 1.0,
      abort_check: proc { false },
      now_proc: proc { ticks.shift || 1.3 }
    )

    signal = guard.check!(0)

    assert_equal 'timeout', signal.reason
    assert_equal 0, signal.iteration_count
    assert_operator signal.elapsed_ms, :>=, 1_300
  end

  test "chatbot loop guard blocks repeated identical results" do
    guard = RedmineTxMcp::ChatbotLoopGuard.new
    params = { 'id' => 123 }

    5.times do
      guard.record_call('issue_get', params)
      guard.record_outcome('issue_get', params, { 'id' => 123, 'status' => 'New' })
    end

    decision = guard.detect_before_call('issue_get', params)

    assert_equal true, decision.blocked
    assert_equal 'no_progress', decision.detector
    assert_equal 6, decision.count
  end

  test "chatbot loop guard does not block progressing repeated reads" do
    guard = RedmineTxMcp::ChatbotLoopGuard.new
    params = { 'id' => 123 }

    5.times do |index|
      guard.record_call('issue_get', params)
      guard.record_outcome('issue_get', params, { 'id' => 123, 'status' => "S#{index}" })
    end

    decision = guard.detect_before_call('issue_get', params)

    assert_equal false, decision.blocked
  end

  test "chatbot loop guard blocks ping pong loops" do
    guard = RedmineTxMcp::ChatbotLoopGuard.new
    issue_params = { 'id' => 123 }
    user_params = { 'id' => 7 }

    3.times do
      guard.record_call('issue_get', issue_params)
      guard.record_outcome('issue_get', issue_params, { 'id' => 123, 'status' => 'New' })
      guard.record_call('user_get', user_params)
      guard.record_outcome('user_get', user_params, { 'id' => 7, 'login' => 'alice' })
    end

    decision = guard.detect_before_call('issue_get', issue_params)

    assert_equal true, decision.blocked
    assert_equal 'ping_pong', decision.detector
  end

  test "resolve_response stops on hard iteration cap" do
    chatbot = build_chatbot
    chatbot.instance_variable_set(:@tool_call_budget, 10)
    chatbot.instance_variable_set(
      :@run_guard,
      RedmineTxMcp::ChatbotRunGuard.new(
        max_iterations: 1,
        max_elapsed_seconds: 60,
        abort_check: proc { false },
        now_proc: proc { 0.0 }
      )
    )

    response = {
      'content' => [
        { 'type' => 'tool_use', 'id' => 'tool-1', 'name' => 'issue_get', 'input' => { 'id' => 123 } }
      ]
    }

    chatbot.stub(:handle_tool_calls, lambda { |_resp, event_handler: nil|
      response
    }) do
      result = chatbot.send(:resolve_response, response, '이슈 123 조회')
      text = chatbot.send(:extract_text_content, result)

      assert_match(/반복 횟수 제한/, text)
      assert_equal 'hard_cap', chatbot.instance_variable_get(:@run_stop_reason)
    end
  end

  test "resolve_response stops on abort at iteration boundary" do
    chatbot = build_chatbot
    chatbot.instance_variable_set(:@tool_call_budget, 10)
    abort_requested = false
    chatbot.instance_variable_set(
      :@run_guard,
      RedmineTxMcp::ChatbotRunGuard.new(
        max_iterations: 3,
        max_elapsed_seconds: 60,
        abort_check: proc { abort_requested },
        now_proc: proc { 0.0 }
      )
    )

    response = {
      'content' => [
        { 'type' => 'tool_use', 'id' => 'tool-1', 'name' => 'issue_get', 'input' => { 'id' => 123 } }
      ]
    }

    chatbot.stub(:handle_tool_calls, lambda { |_resp, event_handler: nil|
      abort_requested = true
      response
    }) do
      result = chatbot.send(:resolve_response, response, '이슈 123 조회')
      text = chatbot.send(:extract_text_content, result)

      assert_match(/중단/, text)
      assert_equal 'abort', chatbot.instance_variable_get(:@run_stop_reason)
    end
  end

  test "handle_tool_calls blocks repeated no progress reads before execution" do
    chatbot = build_chatbot
    response = {
      'content' => [
        { 'type' => 'tool_use', 'id' => 'tool-1', 'name' => 'issue_get', 'input' => { 'id' => 123 } }
      ]
    }

    execution_count = 0
    chatbot.stub(:execute_mcp_tool, lambda { |_tool_name, _tool_input|
      execution_count += 1
      { 'id' => 123, 'status' => 'New' }
    }) do
      chatbot.stub(:invoke_model, lambda { |request_body, thinking_message: nil, event_handler: nil|
        { 'content' => [{ 'type' => 'text', 'text' => 'ok' }] }
      }) do
        5.times { chatbot.send(:handle_tool_calls, response) }
        chatbot.send(:handle_tool_calls, response)
      end
    end

    assert_equal 5, execution_count
    last_history_entry = chatbot.instance_variable_get(:@conversation_history).last
    block_result = last_history_entry[:content].last
    assert_match(/\[loop_guard:no_progress\]/, block_result[:content])
  end

  test "guard retry requires read back verification after successful write" do
    chatbot = build_chatbot
    chatbot.send(:select_tools_for_query, '이슈 123 상태를 QA로 변경해줘')

    workflow = chatbot.instance_variable_get(:@mutation_workflow)
    workflow.record_tool_result(
      'issue_update',
      { 'id' => 123, 'status_id' => 5 },
      { 'id' => 123, 'status' => { 'id' => 5, 'name' => 'QA' } }
    )

    response = {
      'content' => [
        { 'type' => 'text', 'text' => '이슈 123 상태를 QA로 변경했습니다.' }
      ]
    }

    retry_info = chatbot.send(:guard_retry_instruction, response, '이슈 123 상태를 QA로 변경해줘')

    assert_not_nil retry_info
    assert_equal true, retry_info[:force_all_tools]
    assert_match(/read-back 검증/, retry_info[:instruction])
  end

  test "handle_tool_calls blocks new write until previous mutation is verified" do
    chatbot = build_chatbot
    chatbot.instance_variable_get(:@mutation_workflow).record_tool_result(
      'issue_update',
      { 'id' => 123, 'status_id' => 5 },
      { 'id' => 123, 'status' => { 'id' => 5, 'name' => 'QA' } }
    )

    response = {
      'content' => [
        { 'type' => 'tool_use', 'id' => 'tool-1', 'name' => 'issue_relation_create', 'input' => { 'issue_id' => 123, 'related_issue_id' => 124, 'relation_type' => 'relates' } }
      ]
    }

    executed_tools = []

    chatbot.stub(:execute_mcp_tool, lambda { |tool_name, _tool_input|
      executed_tools << tool_name
      { 'ok' => true }
    }) do
      chatbot.stub(:invoke_model, lambda { |request_body, thinking_message: nil, event_handler: nil|
        { 'content' => [{ 'type' => 'text', 'text' => 'next step' }] }
      }) do
        chatbot.send(:handle_tool_calls, response)
      end
    end

    assert_equal [], executed_tools
    last_history_entry = chatbot.instance_variable_get(:@conversation_history).last
    deferred_result = last_history_entry[:content].last
    assert_match(/read-back 검증이 아직 끝나지 않았습니다/, deferred_result[:content])
  end

  test "handle_tool_calls records verification notes and clears pending mutation after matching issue_get" do
    chatbot = build_chatbot
    update_response = {
      'content' => [
        { 'type' => 'tool_use', 'id' => 'tool-1', 'name' => 'issue_update', 'input' => { 'id' => 123, 'status_id' => 5 } }
      ]
    }
    verify_response = {
      'content' => [
        { 'type' => 'tool_use', 'id' => 'tool-2', 'name' => 'issue_get', 'input' => { 'id' => 123 } }
      ]
    }

    chatbot.stub(:execute_mcp_tool, lambda { |tool_name, _tool_input|
      case tool_name
      when 'issue_update'
        { 'id' => 123, 'status' => { 'id' => 5, 'name' => 'QA' } }
      when 'issue_get'
        { 'id' => 123, 'status' => { 'id' => 5, 'name' => 'QA' } }
      else
        { 'ok' => true }
      end
    }) do
      chatbot.stub(:invoke_model, lambda { |request_body, thinking_message: nil, event_handler: nil|
        { 'content' => [{ 'type' => 'text', 'text' => 'next step' }] }
      }) do
        chatbot.send(:handle_tool_calls, update_response)
        assert_equal true, chatbot.instance_variable_get(:@mutation_workflow).pending_verification?

        chatbot.send(:handle_tool_calls, verify_response)
      end
    end

    assert_equal false, chatbot.instance_variable_get(:@mutation_workflow).pending_verification?
    last_history_entry = chatbot.instance_variable_get(:@conversation_history).last
    verification_result = last_history_entry[:content].last
    assert_match(/검증이 통과했습니다/, verification_result[:content])
  end

  test "session state export and restore preserves mutation evidence for ambiguous follow up" do
    chatbot = build_chatbot
    workflow = chatbot.instance_variable_get(:@mutation_workflow)
    workflow.record_tool_result('issue_get', { 'id' => 123 }, { 'id' => 123, 'status' => { 'id' => 1, 'name' => 'New' } })
    workflow.record_tool_result('spreadsheet_list_uploads', {}, { 'files' => [{ 'stored_name' => 'report.xlsx' }] })
    workflow.record_tool_result(
      'issue_update',
      { 'id' => 123, 'status_id' => 5 },
      { 'id' => 123, 'status' => { 'id' => 5, 'name' => 'QA' } }
    )

    snapshot = chatbot.export_session_state

    restored = build_chatbot
    restored.restore_session_state(snapshot)
    restored.send(:reset_turn_state)
    restored.send(:reset_metrics)
    restored.send(:select_tools_for_query, '계속 진행해줘')

    tool_names = restored.send(:available_mcp_tools).map { |tool| tool[:name] }

    assert_includes tool_names, 'issue_get'
    assert_includes tool_names, 'issue_update'
    assert_includes tool_names, 'spreadsheet_list_uploads'
    assert_equal 'report.xlsx', restored.instance_variable_get(:@mutation_workflow).active_workspace_file
  end

  test "prepare_messages_for_model compacts older history and keeps workflow evidence" do
    chatbot = build_chatbot
    workflow = chatbot.instance_variable_get(:@mutation_workflow)
    workflow.record_tool_result('issue_get', { 'id' => 123 }, { 'id' => 123, 'status' => { 'id' => 1, 'name' => 'New' } })
    workflow.record_tool_result('spreadsheet_list_uploads', {}, { 'files' => [{ 'stored_name' => 'report.xlsx' }] })

    20.times do |index|
      role = index.even? ? 'user' : 'assistant'
      chatbot.send(:add_to_conversation, role, "message #{index} " * 200)
    end

    original_size = chatbot.instance_variable_get(:@conversation_history).size
    prepared = chatbot.send(
      :prepare_messages_for_model,
      chatbot.instance_variable_get(:@conversation_history),
      trigger: 'manual_compaction',
      force_compaction: true
    )

    first_message = prepared.first[:content] || prepared.first['content']
    assert_match(/\[Earlier conversation summary/, first_message)
    assert_match(/Recent issue IDs: #123/, first_message)
    assert_match(/report\.xlsx/, first_message)
    assert_operator prepared.size, :<, original_size
    assert_equal original_size, chatbot.instance_variable_get(:@conversation_history).size
  end

  test "invoke_model compacts and retries after context overflow" do
    chatbot = build_chatbot

    18.times do |index|
      role = index.even? ? 'user' : 'assistant'
      chatbot.send(:add_to_conversation, role, "history #{index} " * 120)
    end

    request_body = chatbot.send(:build_request_body, messages: chatbot.instance_variable_get(:@conversation_history))
    attempts = []

    chatbot.stub(:call_claude_api, lambda { |body, provider: chatbot.instance_variable_get(:@provider), &block|
      attempts << body
      if attempts.size == 1
        raise RedmineTxMcp::ClaudeChatbot::ProviderRequestError.new(
          'maximum context length exceeded',
          provider: provider,
          context_overflow: true
        )
      end

      { 'content' => [{ 'type' => 'text', 'text' => 'ok' }], 'usage' => {} }
    }) do
      result = chatbot.send(:invoke_model, request_body)
      assert_equal 'ok', chatbot.send(:extract_text_content, result)
    end

    assert_equal 2, attempts.size
    compacted_messages = attempts.last[:messages] || attempts.last['messages']
    compacted_summary = compacted_messages.first[:content] || compacted_messages.first['content']
    assert_match(/trigger=context_overflow/, compacted_summary)
    assert_equal 1, chatbot.instance_variable_get(:@metrics)[:context_overflow_retries]
  end

  test "invoke_model falls back to alternate provider on retryable error" do
    chatbot = RedmineTxMcp::ClaudeChatbot.new(
      api_key: 'anthropic-test-key',
      provider: 'anthropic',
      endpoint_url: 'http://example.test/v1/chat/completions',
      model: 'test-model'
    )

    request_body = chatbot.send(:build_request_body, messages: [{ role: 'user', content: '상태 알려줘' }])
    attempts = []
    events = []

    chatbot.stub(:call_claude_api, lambda { |_body, provider: chatbot.instance_variable_get(:@provider), &block|
      attempts << provider
      if provider == 'anthropic'
        raise RedmineTxMcp::ClaudeChatbot::ProviderRequestError.new(
          'Anthropic API Error: 503',
          provider: provider,
          retryable: true,
          http_status: 503
        )
      end

      { 'content' => [{ 'type' => 'text', 'text' => 'fallback ok' }], 'usage' => {} }
    }) do
      result = chatbot.send(:invoke_model, request_body, event_handler: proc { |event| events << event })
      assert_equal 'fallback ok', chatbot.send(:extract_text_content, result)
    end

    assert_equal %w[anthropic openai], attempts
    fallback_event = events.find { |event| event[:type] == 'phase' && event[:phase] == 'provider_fallback' }
    refute_nil fallback_event
    assert_equal 'anthropic', fallback_event[:from]
    assert_equal 'openai', fallback_event[:to]
  end

  test "invoke_model does not fallback after write when verification phase is not pending" do
    chatbot = RedmineTxMcp::ClaudeChatbot.new(
      api_key: 'anthropic-test-key',
      provider: 'anthropic',
      endpoint_url: 'http://example.test/v1/chat/completions',
      model: 'test-model'
    )
    chatbot.instance_variable_set(:@write_tool_calls, 1)

    request_body = chatbot.send(:build_request_body, messages: [{ role: 'user', content: '상태 알려줘' }])
    attempts = []

    error = assert_raises(RedmineTxMcp::ClaudeChatbot::ProviderRequestError) do
      chatbot.stub(:call_claude_api, lambda { |_body, provider: chatbot.instance_variable_get(:@provider), &block|
        attempts << provider
        raise RedmineTxMcp::ClaudeChatbot::ProviderRequestError.new(
          'Anthropic API Error: 503',
          provider: provider,
          retryable: true,
          http_status: 503
        )
      }) do
        chatbot.send(:invoke_model, request_body)
      end
    end

    assert_match(/503/, error.message)
    assert_equal ['anthropic'], attempts
    assert_equal 0, chatbot.instance_variable_get(:@metrics)[:provider_fallbacks]
  end

  test "invoke_model falls back after a successful write when provider fails during follow-up reasoning" do
    chatbot = RedmineTxMcp::ClaudeChatbot.new(
      api_key: 'anthropic-test-key',
      provider: 'anthropic',
      endpoint_url: 'http://example.test/v1/chat/completions',
      model: 'test-model'
    )
    chatbot.instance_variable_set(:@write_tool_calls, 1)
    chatbot.instance_variable_set(:@successful_write_tool_calls, 1)

    request_body = chatbot.send(:build_request_body, messages: [{ role: 'user', content: '상태 알려줘' }])
    attempts = []

    chatbot.stub(:call_claude_api, lambda { |_body, provider: chatbot.instance_variable_get(:@provider), &block|
      attempts << provider
      if provider == 'anthropic'
        raise RedmineTxMcp::ClaudeChatbot::ProviderRequestError.new(
          'Anthropic API Error: 503',
          provider: provider,
          retryable: true,
          http_status: 503
        )
      end

      { 'content' => [{ 'type' => 'text', 'text' => 'fallback after write ok' }], 'usage' => {} }
    }) do
      result = chatbot.send(:invoke_model, request_body)
      assert_equal 'fallback after write ok', chatbot.send(:extract_text_content, result)
    end

    assert_equal %w[anthropic openai], attempts
    assert_equal 1, chatbot.instance_variable_get(:@metrics)[:provider_fallbacks]
  end

  test "mutation workflow numeric comparison rejects nil for zero" do
    workflow = RedmineTxMcp::ChatbotMutationWorkflow.new

    assert_equal false, workflow.send(:comparable_values?, 0, nil)
    assert_equal false, workflow.send(:comparable_values?, 0, '')
    assert_equal true, workflow.send(:comparable_values?, 0, '0')
  end

  test "mutation workflow verifies auto schedule apply with bulk issue_get readback" do
    workflow = RedmineTxMcp::ChatbotMutationWorkflow.new

    note = workflow.record_tool_result(
      'issue_auto_schedule_apply',
      { 'preview_token' => 'preview-token' },
      {
        'updated_issue_ids' => [101, 102],
        'issues' => [
          { 'id' => 101, 'start_date' => '2026-03-26', 'due_date' => '2026-03-27' },
          { 'id' => 102, 'start_date' => '2026-03-28', 'due_date' => '2026-03-29' }
        ]
      }
    )

    assert_match(/read-back 검증이 필요합니다/, note)
    assert_equal true, workflow.pending_verification?

    verify_note = workflow.record_tool_result(
      'issue_get',
      { 'ids' => [101, 102] },
      {
        'issues' => [
          { 'id' => 101, 'start_date' => '2026-03-26', 'due_date' => '2026-03-27' },
          { 'id' => 102, 'start_date' => '2026-03-28', 'due_date' => '2026-03-29' }
        ],
        'total' => 2
      }
    )

    assert_equal false, workflow.pending_verification?
    assert_match(/자동 일정 적용 read-back 검증이 통과했습니다/, verify_note)
  end

  test "handle_tool_calls emits phase and verify events for mutation workflow" do
    chatbot = build_chatbot
    response = {
      'content' => [
        { 'type' => 'tool_use', 'id' => 'tool-1', 'name' => 'issue_update', 'input' => { 'id' => 123, 'status_id' => 5 } }
      ]
    }
    events = []

    chatbot.stub(:execute_mcp_tool, lambda { |_tool_name, _tool_input|
      { 'id' => 123, 'status' => { 'id' => 5, 'name' => 'QA' } }
    }) do
      chatbot.stub(:invoke_model, lambda { |request_body, thinking_message: nil, event_handler: nil|
        { 'content' => [{ 'type' => 'text', 'text' => 'next step' }] }
      }) do
        chatbot.send(:handle_tool_calls, response, event_handler: proc { |event| events << event })
      end
    end

    phase_event = events.find { |event| event[:type] == 'phase' && event[:phase] == 'write' }
    verify_event = events.find { |event| event[:type] == 'verify' && event[:status] == 'pending' }

    refute_nil phase_event
    refute_nil verify_event
    assert_equal 'issue_update', phase_event[:tool]
    assert_equal 'issue_update', verify_event[:tool]
    assert_includes verify_event[:verify_with], 'issue_get'
  end

  test "resolve_response emits stop reason events" do
    chatbot = build_chatbot
    chatbot.instance_variable_set(:@tool_call_budget, 10)
    chatbot.instance_variable_set(
      :@run_guard,
      RedmineTxMcp::ChatbotRunGuard.new(
        max_iterations: 1,
        max_elapsed_seconds: 60,
        abort_check: proc { false },
        now_proc: proc { 0.0 }
      )
    )

    response = {
      'content' => [
        { 'type' => 'tool_use', 'id' => 'tool-1', 'name' => 'issue_get', 'input' => { 'id' => 123 } }
      ]
    }
    events = []

    chatbot.stub(:handle_tool_calls, lambda { |_resp, event_handler: nil|
      response
    }) do
      chatbot.send(:resolve_response, response, '이슈 123 조회', event_handler: proc { |event| events << event })
    end

    stop_event = events.find { |event| event[:type] == 'stop_reason' }
    refute_nil stop_event
    assert_equal 'hard_cap', stop_event[:reason]
  end
end
