module RedmineTxMcp
  module Tools
    class IssueTool < BaseTool
      class << self
        def available_tools
          [
            {
              name: "issue_list",
              description: "Search and filter issues with rich filtering. Supports stage-based filtering, date ranges, overdue detection, and sorting. Use this for any issue search or listing need.",
              inputSchema: {
                type: "object",
                properties: {
                  project_id: { type: "integer", description: "Filter by project ID" },
                  status_id: { type: "integer", description: "Filter by specific status ID" },
                  stage: { type: "integer", description: "Filter by stage value (-2=discarded, -1=postponed, 0=new, 1=scoping, 2=in_progress, 3=review, 4=implemented, 5=qa, 6=completed). Returns all statuses matching this stage." },
                  is_open: { type: "boolean", description: "true=open issues only, false=closed only. Omit for all." },
                  is_overdue: { type: "boolean", description: "true=only issues past due_date that are still open" },
                  assigned_to_id: { type: "integer", description: "Filter by assignee user ID" },
                  author_id: { type: "integer", description: "Filter by author user ID" },
                  tracker_id: { type: "integer", description: "Filter by tracker ID" },
                  priority_id: { type: "integer", description: "Filter by priority ID" },
                  category_id: { type: "integer", description: "Filter by category ID" },
                  fixed_version_id: { type: "integer", description: "Filter by target version/milestone ID" },
                  parent_id: { type: "integer", description: "Filter by parent issue ID (direct children only)" },
                  subject: { type: "string", description: "Search in subject (case-insensitive partial match)" },
                  updated_since: { type: "string", description: "Issues updated on or after this date (YYYY-MM-DD)" },
                  created_since: { type: "string", description: "Issues created on or after this date (YYYY-MM-DD)" },
                  due_date_from: { type: "string", description: "Due date on or after (YYYY-MM-DD)" },
                  due_date_to: { type: "string", description: "Due date on or before (YYYY-MM-DD)" },
                  sort: { type: "string", description: "Sort order. Examples: 'due_date:asc', 'priority:desc', 'updated_on:desc', 'id:asc'. Default: 'id:asc'" },
                  page: { type: "integer", description: "Page number", default: 1 },
                  per_page: { type: "integer", description: "Items per page (max 100)", default: 25 }
                }
              }
            },
            {
              name: "issue_get",
              description: "Get full details of a specific issue. Optionally include journals (comments/change history) and children.",
              inputSchema: {
                type: "object",
                properties: {
                  id: { type: "integer", description: "Issue ID" },
                  include_journals: { type: "boolean", description: "Include change history and comments", default: false },
                  include_children: { type: "boolean", description: "Include direct child issues summary", default: false }
                },
                required: ["id"]
              }
            },
            {
              name: "issue_create",
              description: "Create a new issue. Requires project_id, tracker_id, subject. Use enum_trackers to find valid tracker IDs first.",
              inputSchema: {
                type: "object",
                properties: {
                  project_id: { type: "integer", description: "Project ID" },
                  tracker_id: { type: "integer", description: "Tracker ID (use enum_trackers to find valid IDs)" },
                  subject: { type: "string", description: "Issue subject" },
                  description: { type: "string", description: "Issue description" },
                  status_id: { type: "integer", description: "Status ID" },
                  priority_id: { type: "integer", description: "Priority ID" },
                  assigned_to_id: { type: "integer", description: "Assignee user ID" },
                  category_id: { type: "integer", description: "Category ID" },
                  fixed_version_id: { type: "integer", description: "Target version ID" },
                  parent_issue_id: { type: "integer", description: "Parent issue ID" },
                  start_date: { type: "string", description: "Start date (YYYY-MM-DD)" },
                  due_date: { type: "string", description: "Due date (YYYY-MM-DD)" },
                  estimated_hours: { type: "number", description: "Estimated hours" }
                },
                required: ["project_id", "tracker_id", "subject"]
              }
            },
            {
              name: "issue_update",
              description: "Update an existing issue. Only provided fields are changed. Use notes to add a comment.",
              inputSchema: {
                type: "object",
                properties: {
                  id: { type: "integer", description: "Issue ID" },
                  subject: { type: "string", description: "Issue subject" },
                  description: { type: "string", description: "Issue description" },
                  status_id: { type: "integer", description: "Status ID" },
                  priority_id: { type: "integer", description: "Priority ID" },
                  assigned_to_id: { type: "integer", description: "Assignee user ID" },
                  category_id: { type: "integer", description: "Category ID" },
                  fixed_version_id: { type: "integer", description: "Target version ID" },
                  parent_issue_id: { type: "integer", description: "Parent issue ID" },
                  start_date: { type: "string", description: "Start date (YYYY-MM-DD)" },
                  due_date: { type: "string", description: "Due date (YYYY-MM-DD)" },
                  estimated_hours: { type: "number", description: "Estimated hours" },
                  done_ratio: { type: "integer", description: "Done ratio (0-100)" },
                  notes: { type: "string", description: "Comment to add to the issue" }
                },
                required: ["id"]
              }
            },
            {
              name: "issue_delete",
              description: "Delete an issue",
              inputSchema: {
                type: "object",
                properties: {
                  id: { type: "integer", description: "Issue ID" }
                },
                required: ["id"]
              }
            },
            {
              name: "issue_children_summary",
              description: "Get a parent issue with full summary of all its children. Returns: parent details, children grouped by stage, aggregate stats (total/completed/overdue/hours), and alerts (overdue, unassigned, stale issues). Use this to understand the status of a feature/epic.",
              inputSchema: {
                type: "object",
                properties: {
                  parent_id: { type: "integer", description: "Parent issue ID" }
                },
                required: ["parent_id"]
              }
            },
            {
              name: "version_overview",
              description: "Get a version/milestone overview with all parent issues summarized. Each parent shows its children's aggregate progress. Includes version-level alerts (overdue parents, stale parents) and stage distribution. Use this to understand overall release/milestone status.",
              inputSchema: {
                type: "object",
                properties: {
                  version_id: { type: "integer", description: "Version ID" }
                },
                required: ["version_id"]
              }
            },
            {
              name: "bug_statistics",
              description: "Get an aggregate bug dashboard for a project. Returns: " \
                "summary (total/resolved/unresolved/resolution_rate_percent 0-100), " \
                "daily_trend (array of {date, created, resolved, cumulative_unresolved} per day in chronological order), " \
                "unresolved_by_category (top 10 categories as [{category:{id,name} or null, count}], overflow grouped as 'other'), " \
                "unresolved_by_assignee (ranked by count, each with {user:{id,name} or null, total, by_version}). " \
                "Bugs in discarded status are excluded. Only counts bugs within the specified project. " \
                "Use this for aggregate bug metrics and trends; use issue_list with tracker_id for individual bug records.",
              inputSchema: {
                type: "object",
                properties: {
                  project_id: { type: "integer", description: "Project ID" },
                  version_id: { type: "integer", description: "Scope to a version/milestone. Use version_list to find valid IDs." },
                  days: { type: "integer", description: "Trend window in days. Default: 12.", minimum: 1, maximum: 90, default: 12 }
                },
                required: ["project_id"]
              }
            }
          ]
        end

        def call_tool(tool_name, arguments)
          # Layer 2: Extract chatbot context flag (injected by ClaudeChatbot)
          chatbot = !!arguments.delete('_chatbot_context')

          case tool_name
          when "issue_list"
            list_issues(arguments, chatbot: chatbot)
          when "issue_get"
            get_issue(arguments, chatbot: chatbot)
          when "issue_create"
            create_issue(arguments)
          when "issue_update"
            update_issue(arguments)
          when "issue_delete"
            delete_issue(arguments)
          when "issue_children_summary"
            children_summary(arguments, chatbot: chatbot)
          when "version_overview"
            version_overview(arguments, chatbot: chatbot)
          when "bug_statistics"
            bug_statistics(arguments)
          else
            { error: "Unknown tool: #{tool_name}" }
          end
        rescue => e
          handle_error(e)
        end

        private

        # ─── List ───────────────────────────────────────────

        def list_issues(args, chatbot: false)
          scope = Issue.visible

          # Basic filters
          scope = scope.where(project_id: args['project_id']) if args['project_id']
          scope = scope.where(status_id: args['status_id']) if args['status_id']
          scope = scope.where(assigned_to_id: args['assigned_to_id']) if args['assigned_to_id']
          scope = scope.where(author_id: args['author_id']) if args['author_id']
          scope = scope.where(tracker_id: args['tracker_id']) if args['tracker_id']
          scope = scope.where(priority_id: args['priority_id']) if args['priority_id']
          scope = scope.where(category_id: args['category_id']) if args['category_id']
          scope = scope.where(fixed_version_id: args['fixed_version_id']) if args['fixed_version_id']
          scope = scope.where(parent_id: args['parent_id']) if args['parent_id']

          # Stage filter (requires advanced_issue_status plugin)
          if args['stage'] && IssueStatus.respond_to?(:where)
            stage_status_ids = IssueStatus.where(stage: args['stage']).pluck(:id)
            scope = scope.where(status_id: stage_status_ids)
          end

          # Open/Closed filter
          if args.key?('is_open')
            if args['is_open']
              scope = scope.open
            else
              closed_ids = IssueStatus.where(is_closed: true).pluck(:id)
              scope = scope.where(status_id: closed_ids)
            end
          end

          # Overdue filter
          if args['is_overdue']
            scope = scope.open.where("#{Issue.table_name}.due_date < ?", Date.today)
          end

          # Text search
          if args['subject']
            scope = scope.where("LOWER(#{Issue.table_name}.subject) LIKE ?", "%#{args['subject'].downcase}%")
          end

          # Date filters
          if args['updated_since']
            scope = scope.where("#{Issue.table_name}.updated_on >= ?", Date.parse(args['updated_since']))
          end
          if args['created_since']
            scope = scope.where("#{Issue.table_name}.created_on >= ?", Date.parse(args['created_since']))
          end
          if args['due_date_from']
            scope = scope.where("#{Issue.table_name}.due_date >= ?", Date.parse(args['due_date_from']))
          end
          if args['due_date_to']
            scope = scope.where("#{Issue.table_name}.due_date <= ?", Date.parse(args['due_date_to']))
          end

          scope = scope.includes(:project, :status, :tracker, :priority, :assigned_to, :author)

          # Sorting
          scope = apply_sort(scope, args['sort'])

          # Pagination — chatbot hard caps at 25 per page to prevent token explosion
          page = [args['page'].to_i, 1].max
          max_per_page = chatbot ? 25 : 100
          default_per_page = chatbot ? 10 : 25
          per_page = args['per_page'].to_i > 0 ? [[args['per_page'].to_i, 1].max, max_per_page].min : default_per_page
          total = scope.count
          offset = (page - 1) * per_page
          items = scope.offset(offset).limit(per_page).to_a

          {
            items: items.map { |issue| format_issue_details(issue, chatbot: chatbot) },
            pagination: {
              page: page,
              per_page: per_page,
              total_count: total,
              total_pages: (total.to_f / per_page).ceil
            }
          }
        end

        # ─── Get ────────────────────────────────────────────

        def get_issue(args, chatbot: false)
          issue = Issue.visible.find(args['id'])
          result = format_issue_details(issue, chatbot: chatbot)

          if args['include_journals']
            result[:journals] = issue.journals.includes(:user, :details).order(:created_on).map do |journal|
              {
                id: journal.id,
                user: journal.user ? { id: journal.user.id, name: journal.user.name } : nil,
                notes: journal.notes,
                created_on: journal.created_on&.iso8601,
                details: journal.visible_details.map do |detail|
                  { property: detail.property, field: detail.prop_key, old_value: detail.old_value, new_value: detail.value }
                end
              }
            end
          end

          if args['include_children']
            children = issue.children.visible.includes(:status, :assigned_to, :tracker).to_a
            result[:children] = children.map { |c| format_child_brief(c) }
          end

          result
        rescue ActiveRecord::RecordNotFound
          { error: "Issue not found" }
        end

        # ─── Create ─────────────────────────────────────────

        def create_issue(args)
          issue = Issue.new
          issue.project_id = args['project_id']
          issue.tracker_id = args['tracker_id']
          issue.subject = args['subject']
          issue.description = args['description'] if args['description']
          issue.status_id = args['status_id'] if args['status_id']
          issue.priority_id = args['priority_id'] if args['priority_id']
          issue.assigned_to_id = args['assigned_to_id'] if args['assigned_to_id']
          issue.category_id = args['category_id'] if args['category_id']
          issue.fixed_version_id = args['fixed_version_id'] if args['fixed_version_id']
          issue.parent_issue_id = args['parent_issue_id'] if args['parent_issue_id']
          issue.start_date = Date.parse(args['start_date']) if args['start_date']
          issue.due_date = Date.parse(args['due_date']) if args['due_date']
          issue.estimated_hours = args['estimated_hours'] if args['estimated_hours']
          issue.author = User.current

          if issue.save
            format_issue_details(issue)
          else
            { error: "Failed to create issue", validation_errors: issue.errors.full_messages }
          end
        end

        # ─── Update ─────────────────────────────────────────

        def update_issue(args)
          issue = Issue.visible.find(args['id'])

          issue.subject = args['subject'] if args['subject']
          issue.description = args['description'] if args['description']
          issue.status_id = args['status_id'] if args['status_id']
          issue.priority_id = args['priority_id'] if args['priority_id']
          issue.assigned_to_id = args['assigned_to_id'] if args['assigned_to_id']
          issue.category_id = args['category_id'] if args['category_id']
          issue.fixed_version_id = args['fixed_version_id'] if args['fixed_version_id']
          issue.parent_issue_id = args['parent_issue_id'] if args['parent_issue_id']
          issue.start_date = Date.parse(args['start_date']) if args['start_date']
          issue.due_date = Date.parse(args['due_date']) if args['due_date']
          issue.estimated_hours = args['estimated_hours'] if args['estimated_hours']
          issue.done_ratio = args['done_ratio'] if args['done_ratio']
          issue.notes = args['notes'] if args['notes']

          if issue.save
            format_issue_details(issue)
          else
            { error: "Failed to update issue", validation_errors: issue.errors.full_messages }
          end
        rescue ActiveRecord::RecordNotFound
          { error: "Issue not found" }
        end

        # ─── Delete ─────────────────────────────────────────

        def delete_issue(args)
          issue = Issue.visible.find(args['id'])

          if issue.destroy
            { success: true, message: "Issue ##{args['id']} deleted" }
          else
            { error: "Failed to delete issue", validation_errors: issue.errors.full_messages }
          end
        rescue ActiveRecord::RecordNotFound
          { error: "Issue not found" }
        end

        # ─── Children Summary ───────────────────────────────

        def children_summary(args, chatbot: false)
          parent = Issue.visible.find(args['parent_id'])
          children = parent.children.visible.includes(:status, :tracker, :assigned_to, :priority, :children).to_a

          today = Date.today
          grouped = {}
          alerts = []

          children.each do |child|
            stage_name = get_stage_name(child)

            # 완료된 일감, 비일정 리프(버그/예외)는 집계만, 개별 출력 제외
            unless child.status.is_closed? || non_schedule_leaf?(child)
              grouped[stage_name] ||= []
              grouped[stage_name] << format_child_brief(child)
            end

            # Detect alerts
            if child.due_date && child.due_date < today && !child.status.is_closed?
              alerts << { type: "overdue", issue_id: child.id, subject: child.subject, due_date: child.due_date.iso8601, days_overdue: (today - child.due_date).to_i }
            end
            if child.assigned_to.nil? && !child.status.is_closed?
              alerts << { type: "unassigned", issue_id: child.id, subject: child.subject }
            end
            if !child.status.is_closed? && child.updated_on < (Time.now - 7.days)
              alerts << { type: "stale", issue_id: child.id, subject: child.subject, days_since_update: ((Time.now - child.updated_on) / 1.day).to_i }
            end
          end

          open_children = children.reject { |c| c.status.is_closed? }
          closed_children = children.select { |c| c.status.is_closed? }
          overdue_children = open_children.select { |c| c.due_date && c.due_date < today }

          summary = {
            total: children.size,
            completed: closed_children.size,
            in_progress: open_children.size,
            overdue: overdue_children.size,
            done_ratio: children.size > 0 ? (children.sum(&:done_ratio) / children.size.to_f).round(1) : 0,
            estimated_hours: children.sum(&:estimated_hours).to_f,
            spent_hours: children.sum(&:spent_hours).to_f
          }
          summary[:by_type] = build_type_breakdown(children) if Tracker.respond_to?(:is_bug?)

          {
            parent: format_issue_details(parent, chatbot: chatbot),
            summary: summary,
            children_by_stage: grouped,
            alerts: alerts
          }
        rescue ActiveRecord::RecordNotFound
          { error: "Issue not found" }
        end

        # ─── Version Overview ───────────────────────────────

        def version_overview(args, chatbot: false)
          version = Version.find(args['version_id'])
          all_issues = version.fixed_issues.visible.includes(:status, :tracker, :assigned_to, :priority, :children).to_a

          # Separate parent issues (have children) and standalone issues
          parent_issues = all_issues.select { |i| i.children.any? }
          standalone_issues = all_issues.select { |i| i.parent_id.nil? && i.children.empty? }

          today = Date.today
          alerts = []
          stage_counts = Hash.new(0)

          parent_summaries = parent_issues.filter_map do |parent|
            children = parent.children.visible.includes(:status, :assigned_to).to_a

            stage_name = get_stage_name(parent)
            stage_counts[stage_name] += 1

            # 완료된 부모는 stage_counts만 반영, 상세 출력 제외
            next if parent.status.is_closed?

            open_children = children.reject { |c| c.status.is_closed? }
            overdue_children = open_children.select { |c| c.due_date && c.due_date < today }

            # Alerts
            if overdue_children.any?
              alerts << { type: "overdue_children", parent_id: parent.id, subject: parent.subject, overdue_count: overdue_children.size }
            end
            if !parent.status.is_closed? && parent.updated_on < (Time.now - 7.days)
              alerts << { type: "stale", parent_id: parent.id, subject: parent.subject, days_since_update: ((Time.now - parent.updated_on) / 1.day).to_i }
            end

            parent_summary = {
              id: parent.id,
              subject: parent.subject,
              tracker: parent.tracker.name,
              assigned_to: parent.assigned_to ? parent.assigned_to.name : nil,
              stage: stage_name,
              done_ratio: parent.done_ratio,
              children_total: children.size,
              children_completed: children.count { |c| c.status.is_closed? },
              children_in_progress: open_children.size,
              children_overdue: overdue_children.size,
              estimated_hours: children.sum(&:estimated_hours).to_f,
              spent_hours: children.sum(&:spent_hours).to_f,
              due_date: parent.due_date&.iso8601
            }.merge(issue_tip_fields(parent))
            parent_summary[:children_by_type] = build_type_breakdown(children) if Tracker.respond_to?(:is_bug?)
            parent_summary
          end

          # Include standalone issues in stage counts
          standalone_issues.each { |i| stage_counts[get_stage_name(i)] += 1 }
          standalone_open = standalone_issues.reject { |i| i.status.is_closed? || non_schedule_leaf?(i) }

          sorted_summaries = parent_summaries.sort_by { |p| [p[:children_overdue] > 0 ? 0 : 1, -(p[:children_total] - p[:children_completed])] }

          # Chatbot mode: limit parent issues to reduce token usage
          truncated_notice = nil
          if chatbot && sorted_summaries.size > 30
            truncated_notice = "Showing 30 of #{sorted_summaries.size} parent issues (sorted by priority). Use issue_children_summary for details on specific parents."
            sorted_summaries = sorted_summaries.first(30)
          end

          result = {
            version: {
              id: version.id,
              name: version.name,
              status: version.status,
              due_date: version.effective_date&.iso8601,
              done_ratio: version.completed_percent,
              overdue: version.overdue?,
              total_issues: all_issues.size
            },
            parent_issues: sorted_summaries,
            standalone_issues_count: standalone_open.size,
            stage_summary: stage_counts,
            alerts: alerts
          }
          result[:notice] = truncated_notice if truncated_notice
          result
        rescue ActiveRecord::RecordNotFound
          { error: "Version not found" }
        end

        # ─── Bug Statistics ──────────────────────────────────

        def bug_statistics(args)
          project = Project.find(args['project_id'])
          days = (args['days'] || 12).to_i.clamp(1, 90)

          # Resolve bug tracker IDs
          bug_tracker_ids = if Tracker.respond_to?(:bug_trackers_ids)
                              Tracker.bug_trackers_ids
                            else
                              Tracker.where(name: /bug/i).pluck(:id)
                            end
          return { error: "No bug trackers configured" } if bug_tracker_ids.empty?

          # Exclude discarded statuses
          discarded_ids = if IssueStatus.respond_to?(:discarded_ids)
                            IssueStatus.discarded_ids
                          else
                            []
                          end

          # Base scope: bugs in project, not discarded
          scope = Issue.where(project_id: project.id, tracker_id: bug_tracker_ids)
          scope = scope.where.not(status_id: discarded_ids) if discarded_ids.any?

          # Optional version filter
          version = nil
          if args['version_id']
            version = Version.find(args['version_id'])
            scope = scope.where(fixed_version_id: version.id)
          end

          # Load all matching bugs into memory
          all_bugs = scope.includes(:status, :category, :assigned_to, :fixed_version).to_a

          # Summary
          resolved = all_bugs.select { |b| bug_resolved?(b) }
          unresolved = all_bugs.reject { |b| bug_resolved?(b) }
          total = all_bugs.size
          resolution_rate_percent = total > 0 ? (resolved.size * 100.0 / total).round(1) : 0.0

          # Daily trend
          today = Date.today
          if version&.effective_date
            today = [today, version.effective_date + 2.days].min
          end

          trend_start = today - (days - 1).days
          daily_trend = (0...days).map do |i|
            day = trend_start + i.days
            created = all_bugs.count { |b| b.created_on.to_date == day }
            resolved_on_day = all_bugs.count { |b| bug_resolved_date(b) == day }
            created_until = all_bugs.count { |b| b.created_on.to_date <= day }
            resolved_until = all_bugs.count { |b| (d = bug_resolved_date(b)) && d <= day }
            {
              date: day.iso8601,
              created: created,
              resolved: resolved_on_day,
              cumulative_unresolved: created_until - resolved_until
            }
          end

          # Unresolved by category (top 10 + overflow into "other")
          cat_groups = unresolved.group_by { |b| b.category_id }
          cat_id_to_name = {}
          cat_ids = cat_groups.keys.compact
          IssueCategory.where(id: cat_ids).pluck(:id, :name).each { |id, name| cat_id_to_name[id] = name } if cat_ids.any?

          cat_entries = cat_groups.map do |cat_id, bugs|
            cat_info = cat_id ? { id: cat_id, name: cat_id_to_name[cat_id] || "Category##{cat_id}" } : nil
            { category: cat_info, count: bugs.size }
          end.sort_by { |e| -e[:count] }

          if cat_entries.size > 10
            overflow_count = cat_entries.drop(10).sum { |e| e[:count] }
            cat_entries = cat_entries.first(10)
            cat_entries << { category: { id: nil, name: "other" }, count: overflow_count }
          end

          # Unresolved by assignee with version sub-breakdown
          assignee_groups = unresolved.group_by(&:assigned_to_id)
          user_ids = assignee_groups.keys.compact
          user_map = user_ids.any? ? User.where(id: user_ids).index_by(&:id) : {}

          unresolved_by_assignee = assignee_groups.map do |uid, bugs|
            user_info = if uid.nil?
                          nil
                        else
                          u = user_map[uid]
                          { id: uid, name: u ? u.name : "User##{uid}" }
                        end
            by_version = {}
            bugs.each do |b|
              if b.fixed_version
                vname = b.fixed_version.name
              else
                vname = nil
              end
              by_version[vname] = (by_version[vname] || 0) + 1
            end
            { user: user_info, total: bugs.size, by_version: by_version }
          end.sort_by { |e| -e[:total] }

          {
            project: { id: project.id, name: project.name },
            version: version ? { id: version.id, name: version.name, due_date: version.effective_date&.iso8601 } : nil,
            summary: { total: total, resolved: resolved.size, unresolved: unresolved.size, resolution_rate_percent: resolution_rate_percent },
            daily_trend: daily_trend,
            unresolved_by_category: cat_entries,
            unresolved_by_assignee: unresolved_by_assignee
          }
        rescue ActiveRecord::RecordNotFound => e
          { error: e.message.include?("Version") ? "Version not found" : "Project not found" }
        end

        # Resolution detection aligned with milestone plugin: end_time is the primary signal.
        # Fallback to is_closed? only when end_time field is unavailable (plugin not installed).
        def bug_resolved?(issue)
          if issue.respond_to?(:end_time)
            issue.end_time.present?
          else
            issue.status.is_closed?
          end
        end

        def bug_resolved_date(issue)
          if issue.respond_to?(:end_time) && issue.end_time.present?
            issue.end_time.to_date
          elsif !issue.respond_to?(:end_time) && issue.status.is_closed? && issue.closed_on
            issue.closed_on.to_date
          end
        end

        # ─── Helpers ────────────────────────────────────────

        def apply_sort(scope, sort_param)
          return scope.order("#{Issue.table_name}.id ASC") unless sort_param

          field, direction = sort_param.split(':')
          direction = %w[asc desc].include?(direction&.downcase) ? direction.downcase : 'asc'

          sort_map = {
            'id' => "#{Issue.table_name}.id",
            'priority' => "#{IssuePriority.table_name}.position",
            'status' => "#{IssueStatus.table_name}.position",
            'due_date' => "#{Issue.table_name}.due_date",
            'updated_on' => "#{Issue.table_name}.updated_on",
            'created_on' => "#{Issue.table_name}.created_on",
            'assigned_to' => "#{User.table_name}.lastname",
            'subject' => "#{Issue.table_name}.subject",
            'done_ratio' => "#{Issue.table_name}.done_ratio",
            'estimated_hours' => "#{Issue.table_name}.estimated_hours"
          }

          column = sort_map[field]
          return scope.order("#{Issue.table_name}.id ASC") unless column

          # Need joins for priority/status/user sorting
          scope = scope.joins(:priority) if field == 'priority'
          scope = scope.joins(:status) if field == 'status'
          scope = scope.joins("LEFT JOIN #{User.table_name} ON #{User.table_name}.id = #{Issue.table_name}.assigned_to_id") if field == 'assigned_to'

          scope.order(Arel.sql("#{column} #{direction}"))
        end

        def get_stage_name(issue)
          if issue.status.respond_to?(:stage_name) && issue.status.stage_name.present?
            issue.status.stage_name
          elsif issue.status.is_closed?
            "Completed"
          else
            issue.status.name
          end
        end

        def issue_tip_fields(issue)
          return { tip: nil, tip_code: nil } unless issue.respond_to?(:guide_tag)

          code = issue.guide_tag
          { tip: issue.tip, tip_code: code&.to_s }
        end

        # 일정 관리 대상이 아닌 리프 노드 (버그/예외 트래커, 자식 없음)
        def non_schedule_leaf?(issue)
          return false unless Tracker.respond_to?(:is_bug?)
          issue.children.empty? && (Tracker.is_bug?(issue.tracker_id) || Tracker.is_exception?(issue.tracker_id))
        end

        def build_type_breakdown(issues)
          work = []; bug = []; sidejob = []; exception = []
          issues.each do |i|
            tid = i.tracker_id
            if Tracker.is_bug?(tid)
              bug << i
            elsif Tracker.is_sidejob?(tid)
              sidejob << i
            elsif Tracker.is_exception?(tid)
              exception << i
            else
              work << i
            end
          end
          result = {}
          { work: work, bug: bug, sidejob: sidejob, exception: exception }.each do |type, list|
            next if list.empty?
            closed = list.count { |i| i.status.is_closed? }
            result[type] = { total: list.size, completed: closed, open: list.size - closed }
          end
          result
        end

        def format_child_brief(child)
          {
            id: child.id,
            subject: child.subject,
            tracker: child.tracker.name,
            status: child.status.name,
            stage: get_stage_name(child),
            assigned_to: child.assigned_to ? child.assigned_to.name : nil,
            done_ratio: child.done_ratio,
            due_date: child.due_date&.iso8601,
            is_overdue: child.due_date && child.due_date < Date.today && !child.status.is_closed?,
            estimated_hours: child.estimated_hours,
            spent_hours: child.spent_hours
          }.merge(issue_tip_fields(child))
        end

        # chatbot: true omits verbose fields (description, author, category, parent_issue,
        # project, timestamps) to reduce token usage. MCP protocol callers get full details.
        def format_issue_details(issue, chatbot: false)
          if chatbot
            result = {
              id: issue.id,
              subject: issue.subject,
              tracker: issue.tracker.name,
              status: {
                id: issue.status.id,
                name: issue.status.name,
                is_closed: issue.status.is_closed?,
                stage: issue.status.respond_to?(:stage) ? issue.status.stage : nil,
                stage_name: issue.status.respond_to?(:stage_name) ? issue.status.stage_name : nil,
              },
              priority: issue.priority ? issue.priority.name : nil,
              assigned_to: issue.assigned_to ? issue.assigned_to.name : nil,
              fixed_version: issue.fixed_version ? issue.fixed_version.name : nil,
              start_date: issue.start_date&.iso8601,
              due_date: issue.due_date&.iso8601,
              estimated_hours: issue.estimated_hours,
              spent_hours: issue.spent_hours,
              done_ratio: issue.done_ratio,
              worker: issue.respond_to?(:worker) && issue.worker ? issue.worker.name : nil,
            }.merge(issue_tip_fields(issue))
            return result
          end

          {
            id: issue.id,
            subject: issue.subject,
            description: issue.description,
            project: {
              id: issue.project.id,
              name: issue.project.name,
              identifier: issue.project.identifier
            },
            tracker: {
              id: issue.tracker.id,
              name: issue.tracker.name
            },
            status: {
              id: issue.status.id,
              name: issue.status.name,
              is_closed: issue.status.is_closed?,
              stage: issue.status.respond_to?(:stage) ? issue.status.stage : nil,
              stage_name: issue.status.respond_to?(:stage_name) ? issue.status.stage_name : nil,
              is_paused: issue.status.respond_to?(:is_paused?) ? issue.status.is_paused? : nil
            },
            priority: issue.priority ? {
              id: issue.priority.id,
              name: issue.priority.name
            } : nil,
            author: {
              id: issue.author.id,
              name: issue.author.name
            },
            assigned_to: issue.assigned_to ? {
              id: issue.assigned_to.id,
              name: issue.assigned_to.name
            } : nil,
            category: issue.category ? {
              id: issue.category.id,
              name: issue.category.name
            } : nil,
            fixed_version: issue.fixed_version ? {
              id: issue.fixed_version.id,
              name: issue.fixed_version.name
            } : nil,
            parent_issue: issue.parent ? {
              id: issue.parent.id,
              subject: issue.parent.subject
            } : nil,
            start_date: issue.start_date&.iso8601,
            due_date: issue.due_date&.iso8601,
            estimated_hours: issue.estimated_hours,
            spent_hours: issue.spent_hours,
            done_ratio: issue.done_ratio,
            worker: issue.respond_to?(:worker) && issue.worker ? {
              id: issue.worker.id,
              name: issue.worker.name
            } : nil,
            begin_time: issue.respond_to?(:begin_time) ? issue.begin_time&.iso8601 : nil,
            end_time: issue.respond_to?(:end_time) ? issue.end_time&.iso8601 : nil,
            confirm_time: issue.respond_to?(:confirm_time) ? issue.confirm_time&.iso8601 : nil,
            created_on: issue.created_on&.iso8601,
            updated_on: issue.updated_on&.iso8601,
            closed_on: issue.closed_on&.iso8601
          }.merge(issue_tip_fields(issue))
        end
      end
    end
  end
end
