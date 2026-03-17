require File.expand_path('test_helper', __dir__)

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
end
