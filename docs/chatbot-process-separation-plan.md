# Chatbot 프로세스 분리 계획

## 목표

챗봇 LLM 처리를 Redmine 웹 프로세스에서 완전히 분리하여,
챗봇 부하가 Redmine 서비스 전체에 영향을 주지 않도록 한다.

## 현재 구조 (AS-IS)

```
[브라우저] → [Puma Worker] → ChatbotController → ClaudeChatbot → LLM API
                 ↑                                    (동기 블로킹, 최대 수분)
           같은 프로세스에서 일반 Redmine 요청도 처리
```

**문제:** LLM API 호출이 Puma 워커를 장시간 점유 → 워커 고갈 시 Redmine 전체 마비

## 목표 구조 (TO-BE)

```
[브라우저] → [Puma Worker] → ChatbotController (경량 프록시)
                                  ↓ HTTP/Unix Socket (비동기)
                           [Chatbot Worker 프로세스]
                                  ↓
                              LLM API 호출
```

Puma 워커는 요청을 전달하고 즉시 해방. 챗봇 전용 프로세스가 LLM 호출을 담당.

## 구현 방안

### Option A: 별도 Rack 서버 (Puma standalone)

챗봇 전용 소형 Rack 앱을 별도 포트/소켓으로 실행.

```
redmine_tx_mcp/
├── bin/
│   └── chatbot_worker.rb     # 새로 추가: 별도 프로세스 엔트리
├── lib/
│   └── redmine_tx_mcp/
│       └── chatbot_worker/
│           ├── app.rb         # 경량 Rack/Sinatra 앱
│           └── config.ru
```

**장점:** 완전한 프로세스 격리, 독립 스케일링 가능
**단점:** 추가 프로세스 관리 필요, Redmine 모델 접근에 DB 공유 필요

### Option B: DRb (Distributed Ruby) 서비스

Ruby 내장 DRb를 사용하여 별도 프로세스에서 챗봇 실행.

```ruby
# bin/chatbot_worker.rb
require 'drb/drb'
DRb.start_service('druby://localhost:9876', ChatbotService.new)

# ChatbotController에서
chatbot = DRbObject.new_with_uri('druby://localhost:9876')
result = chatbot.chat(message, project_id: @project.id)
```

**장점:** 구현 간단, 추가 gem 불필요
**단점:** DRb 보안 고려 필요, 직렬화 제약

### Option C: Background Job + Polling (권장)

Redmine 환경과 가장 자연스러운 방식. Thread 기반 인메모리 잡 큐 사용 (외부 의존성 없음).

```
[POST /chat] → job_id 즉시 반환 (Puma 워커 해방)
                 ↓ Thread pool에 작업 등록
[GET /chat/status/:job_id] → 폴링으로 결과 확인
                 ↓ 완료 시 결과 반환
```

## 권장안: Option C 상세 설계

### 1. ChatbotJobQueue (새 클래스)

```ruby
# lib/redmine_tx_mcp/chatbot_job_queue.rb
module RedmineTxMcp
  class ChatbotJobQueue
    MAX_WORKERS = 2  # 동시 LLM 호출 수 제한

    Job = Struct.new(:id, :status, :message, :project_id, :user_id,
                     :session_id, :result, :error, :created_at, keyword_init: true)

    def initialize
      @jobs = {}
      @mutex = Mutex.new
      @queue = Queue.new
      @workers = []
      start_workers
    end

    def enqueue(message:, project_id:, user_id:, session_id:)
      job = Job.new(
        id: SecureRandom.hex(8),
        status: :pending,
        message: message,
        project_id: project_id,
        user_id: user_id,
        session_id: session_id,
        created_at: Time.current
      )
      @mutex.synchronize { @jobs[job.id] = job }
      @queue.push(job.id)
      job.id
    end

    def status(job_id)
      @mutex.synchronize { @jobs[job_id]&.to_h }
    end

    def cleanup_old_jobs(max_age: 600)
      cutoff = Time.current - max_age
      @mutex.synchronize do
        @jobs.delete_if { |_, j| j.created_at < cutoff }
      end
    end

    private

    def start_workers
      MAX_WORKERS.times do
        @workers << Thread.new { worker_loop }
      end
    end

    def worker_loop
      loop do
        job_id = @queue.pop  # blocking
        job = @mutex.synchronize { @jobs[job_id] }
        next unless job

        begin
          @mutex.synchronize { job.status = :running }
          result = execute_chat(job)
          @mutex.synchronize do
            job.status = :completed
            job.result = result
          end
        rescue => e
          @mutex.synchronize do
            job.status = :failed
            job.error = e.message
          end
        end
      end
    end

    def execute_chat(job)
      # Redmine 모델 접근을 위한 컨텍스트 설정
      user = User.find(job.user_id)
      User.current = user
      # ClaudeChatbot 생성 및 실행
      chatbot = build_chatbot(job.project_id)
      chatbot.chat(job.message, user: user)
    end
  end
end
```

### 2. Controller 변경

```ruby
class ChatbotController < ApplicationController
  def chat_submit
    # 작업 등록 후 즉시 반환 — Puma 워커 즉시 해방
    job_id = chatbot_queue.enqueue(
      message: params[:message],
      project_id: @project.id,
      user_id: User.current.id,
      session_id: session[session_key]
    )
    render json: { job_id: job_id, status: 'pending' }
  end

  def chat_status
    status = chatbot_queue.status(params[:job_id])
    render json: status || { error: 'Job not found' }
  end

  private

  def chatbot_queue
    @@chatbot_queue ||= RedmineTxMcp::ChatbotJobQueue.new
  end
end
```

### 3. 프론트엔드 변경

```javascript
// 기존: SSE 스트리밍 한 번으로 완료
// 변경: submit → polling → 결과 표시

async function sendMessage(message) {
  // 1. 작업 등록
  const { job_id } = await fetch('/chat', {
    method: 'POST',
    body: JSON.stringify({ message })
  }).then(r => r.json());

  // 2. 폴링
  showThinking();
  while (true) {
    const status = await fetch(`/chat/status/${job_id}`).then(r => r.json());
    if (status.status === 'completed') {
      displayResponse(status.result.message);
      break;
    } else if (status.status === 'failed') {
      displayError(status.error);
      break;
    }
    await sleep(1000);  // 1초 간격 폴링
  }
}
```

### 4. 스트리밍 지원 (Option C 확장)

폴링 대신 SSE를 유지하려면, 컨트롤러가 job 상태를 SSE로 중계:

```ruby
def chat_submit_stream
  job_id = chatbot_queue.enqueue(...)

  self.response_body = Enumerator.new do |yielder|
    loop do
      status = chatbot_queue.status(job_id)
      case status[:status]
      when :completed
        yielder << "data: #{({ type: 'answer', message: status[:result][:message] }).to_json}\n\n"
        yielder << "data: #{({ type: 'done' }).to_json}\n\n"
        break
      when :failed
        yielder << "data: #{({ type: 'error', message: status[:error] }).to_json}\n\n"
        break
      else
        yielder << "data: #{({ type: 'thinking', message: 'Processing...' }).to_json}\n\n"
        sleep 1
      end
    end
  end
end
```

**주의:** 이 방식도 SSE 커넥션이 열려있는 동안 워커를 점유하므로,
완전한 해방을 원하면 폴링 방식이 더 적합함.

## 마이그레이션 단계

### Phase 1: 준비 (현재 완료)
- [x] 동시 요청 제한 (MAX_CONCURRENT_CHATS = 2)
- [ ] Anthropic API 타임아웃 추가
- [ ] max_tool_call_depth 기본값 축소 (10 → 5)

### Phase 2: Job Queue 도입
- [ ] `ChatbotJobQueue` 클래스 구현
- [ ] `chat_submit` / `chat_status` 엔드포인트 분리
- [ ] 프론트엔드 폴링 방식 전환
- [ ] 기존 SSE 스트리밍은 fallback으로 유지

### Phase 3: 프로세스 분리 (필요 시)
- [ ] Job Queue를 별도 프로세스(DRb 또는 HTTP)로 분리
- [ ] systemd 서비스 파일 작성
- [ ] 헬스체크 / 모니터링 추가

## 리스크 및 고려사항

| 항목 | 설명 |
|------|------|
| 메모리 | Thread pool + 인메모리 job 저장소 → 오래된 job 주기적 정리 필요 |
| 프로세스 재시작 | 인메모리이므로 Redmine 재시작 시 진행 중 job 유실 |
| DB 커넥션 | Worker 스레드가 ActiveRecord 사용 시 connection pool 고려 |
| 개발 모드 | Rails 코드 리로딩과 Thread 간 충돌 가능 → production 전용 권장 |
| Puma 클러스터 모드 | @@변수는 프로세스별 독립 → 워커 수만큼 큐가 생김. 해결: Redis 또는 파일 기반 공유 |
