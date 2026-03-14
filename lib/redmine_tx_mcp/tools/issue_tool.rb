module RedmineTxMcp
  module Tools
    class IssueTool < BaseTool
      class << self
        def available_tools
          [
            {
              name: "issue_list",
              description: "Search and filter issues with rich filtering. Returns lightweight summary rows for browsing and candidate selection, including concise relation_summary hints such as whether an issue has predecessors, successors, or blockers. Supports ID filters, name-based filters, null-state filters, relation filters, date ranges, overdue detection, fetch_all for broad lists, and sorting. Use issue_get after you identify one exact issue and need full details, parent info, relations, or journals.",
              inputSchema: {
                type: "object",
                properties: {
                  project_id: { type: "integer", description: "Filter by project ID" },
                  status_id: { type: "integer", description: "Filter by specific status ID" },
                  status_name: { type: "string", description: "Filter by status name (partial match). Use this when the user gives a human-readable status name instead of an ID." },
                  stage: { type: "integer", description: "Filter by stage value (-2=discarded, -1=postponed, 0=new, 1=scoping, 2=in_progress, 3=review, 4=implemented, 5=qa, 6=completed). Returns all statuses matching this stage." },
                  is_open: { type: "boolean", description: "true=open issues only, false=closed only. Omit for all." },
                  is_overdue: { type: "boolean", description: "true=only issues past due_date that are still open" },
                  is_unassigned: { type: "boolean", description: "true=only issues without an assignee, false=only issues with an assignee" },
                  assigned_to_id: { type: "integer", description: "Filter by assignee user ID" },
                  assigned_to_name: { type: "string", description: "Filter by assignee name/login (partial match). Handles compact full-name matching such as 홍길동." },
                  author_id: { type: "integer", description: "Filter by author user ID" },
                  author_name: { type: "string", description: "Filter by author name/login (partial match)" },
                  tracker_id: { type: "integer", description: "Filter by tracker ID" },
                  tracker_name: { type: "string", description: "Filter by tracker name (partial match)" },
                  priority_id: { type: "integer", description: "Filter by priority ID" },
                  priority_name: { type: "string", description: "Filter by priority name (partial match)" },
                  category_id: { type: "integer", description: "Filter by category ID" },
                  category_name: { type: "string", description: "Filter by category name (partial match)" },
                  has_no_category: { type: "boolean", description: "true=only issues without a category, false=only issues with a category" },
                  fixed_version_id: { type: "integer", description: "Filter by target version/milestone ID" },
                  fixed_version_name: { type: "string", description: "Filter by target version/milestone name (partial match)" },
                  has_no_fixed_version: { type: "boolean", description: "true=only issues without a target version, false=only issues with a target version" },
                  parent_id: { type: "integer", description: "Filter by parent issue ID (direct children only)" },
                  is_root_issue: { type: "boolean", description: "true=only top-level issues without a parent, false=only child issues" },
                  related_to_id: { type: "integer", description: "Filter issues that have any visible relation with this issue ID. Use issue_get or issue_relations_get to inspect the exact relation types after finding the matches." },
                  has_relations: { type: "boolean", description: "true=only issues that have at least one relation, false=only issues without relations" },
                  subject: { type: "string", description: "Search in subject (case-insensitive partial match)" },
                  updated_since: { type: "string", description: "Issues updated on or after this date. Accepts YYYY-MM-DD, YYYY/MM/DD, YYYY.MM.DD, today/yesterday/tomorrow, 오늘/어제/내일." },
                  created_since: { type: "string", description: "Issues created on or after this date. Accepts YYYY-MM-DD, YYYY/MM/DD, YYYY.MM.DD, today/yesterday/tomorrow, 오늘/어제/내일." },
                  due_date_from: { type: "string", description: "Due date on or after this date. Accepts YYYY-MM-DD, YYYY/MM/DD, YYYY.MM.DD, today/yesterday/tomorrow, 오늘/어제/내일." },
                  due_date_to: { type: "string", description: "Due date on or before this date. Accepts YYYY-MM-DD, YYYY/MM/DD, YYYY.MM.DD, today/yesterday/tomorrow, 오늘/어제/내일." },
                  has_no_due_date: { type: "boolean", description: "true=only issues without a due date, false=only issues with a due date" },
                  sort: { type: "string", description: "Sort order. Examples: 'due_date:asc', 'priority:desc', 'updated_on:desc', 'id:asc'. Default: 'id:asc'" },
                  fetch_all: { type: "boolean", description: "Return a capped full list in one response. Prefer this when the user asks for all/전체/전부 issues and the result set is manageable." },
                  page: { type: "integer", description: "Page number", default: 1 },
                  per_page: { type: "integer", description: "Items per page (max 100)", default: 25 }
                }
              }
            },
            {
              name: "issue_get",
              description: "Get detailed information for one specific issue. Unlike issue_list, this returns the issue description, project/category, parent issue, and current relations by default. Use this after issue_list when you need to inspect one issue deeply.",
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
              name: "issue_relations_get",
              description: "Get the current visible relations of one issue. Use this when the user asks about predecessors, successors, blockers, duplicates, or dependency chains.",
              inputSchema: {
                type: "object",
                properties: {
                  issue_id: { type: "integer", description: "Issue ID to inspect" },
                  relation_type: { type: "string", description: "Optional relation type from this issue's perspective. Supported: relates, duplicates, duplicated, blocks, blocked, precedes, follows, copied_to, copied_from." }
                },
                required: ["issue_id"]
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
              description: "Update an existing issue. Only provided fields are changed. Use notes to add a comment. Set clearable fields to null to remove them.",
              inputSchema: {
                type: "object",
                properties: {
                  id: { type: "integer", description: "Issue ID" },
                  subject: { type: "string", description: "Issue subject" },
                  description: { type: ["string", "null"], description: "Issue description. Set null to clear." },
                  status_id: { type: "integer", description: "Status ID" },
                  priority_id: { type: "integer", description: "Priority ID" },
                  assigned_to_id: { type: ["integer", "null"], description: "Assignee user ID. Set null to clear." },
                  category_id: { type: ["integer", "null"], description: "Category ID. Set null to clear." },
                  fixed_version_id: { type: ["integer", "null"], description: "Target version ID. Set null to clear." },
                  parent_issue_id: { type: ["integer", "null"], description: "Parent issue ID. Set null to clear." },
                  start_date: { type: ["string", "null"], description: "Start date (YYYY-MM-DD). Set null to clear." },
                  due_date: { type: ["string", "null"], description: "Due date (YYYY-MM-DD). Set null to clear." },
                  estimated_hours: { type: ["number", "null"], description: "Estimated hours. Set null to clear." },
                  done_ratio: { type: "integer", description: "Done ratio (0-100)" },
                  notes: { type: "string", description: "Comment to add to the issue" }
                },
                required: ["id"]
              }
            },
            {
              name: "insert_bulk_update",
              description: "Bulk update multiple existing issues in one call. Prefer this when the same change applies to several issues. By default it is atomic: if any issue fails, no changes are applied. Set clearable fields to null to remove them.",
              inputSchema: {
                type: "object",
                properties: {
                  issue_ids: {
                    type: "array",
                    items: { type: "integer" },
                    description: "Issue IDs to update"
                  },
                  subject: { type: "string", description: "Issue subject" },
                  description: { type: ["string", "null"], description: "Issue description. Set null to clear." },
                  status_id: { type: "integer", description: "Status ID" },
                  priority_id: { type: "integer", description: "Priority ID" },
                  assigned_to_id: { type: ["integer", "null"], description: "Assignee user ID. Set null to clear." },
                  category_id: { type: ["integer", "null"], description: "Category ID. Set null to clear." },
                  fixed_version_id: { type: ["integer", "null"], description: "Target version ID. Set null to clear." },
                  parent_issue_id: { type: ["integer", "null"], description: "Parent issue ID. Set null to clear." },
                  start_date: { type: ["string", "null"], description: "Start date (YYYY-MM-DD). Set null to clear." },
                  due_date: { type: ["string", "null"], description: "Due date (YYYY-MM-DD). Set null to clear." },
                  estimated_hours: { type: ["number", "null"], description: "Estimated hours. Set null to clear." },
                  done_ratio: { type: "integer", description: "Done ratio (0-100)" },
                  notes: { type: "string", description: "Comment to add to every updated issue" },
                  allow_partial_success: {
                    type: "boolean",
                    description: "If true, update what can be updated and report per-issue failures. Default: false"
                  }
                },
                required: ["issue_ids"]
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
              name: "issue_relation_create",
              description: "Create a relation between issue_id and related_issue_id. relation_type is interpreted from issue_id's perspective. Example: if issue_id follows related_issue_id, use relation_type: 'follows'.",
              inputSchema: {
                type: "object",
                properties: {
                  issue_id: { type: "integer", description: "Primary issue ID" },
                  related_issue_id: { type: "integer", description: "Other issue ID to relate" },
                  relation_type: { type: "string", description: "Relation type from issue_id's perspective. Supported: relates, duplicates, duplicated, blocks, blocked, precedes, follows, copied_to, copied_from." },
                  delay: { type: ["integer", "null"], description: "Optional delay in days. Only meaningful for precedes/follows relations." }
                },
                required: ["issue_id", "related_issue_id", "relation_type"]
              }
            },
            {
              name: "issue_relation_delete",
              description: "Delete an existing issue relation by relation ID.",
              inputSchema: {
                type: "object",
                properties: {
                  id: { type: "integer", description: "Issue relation ID" }
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
          when "issue_relations_get"
            get_issue_relations(arguments, chatbot: chatbot)
          when "issue_create"
            create_issue(arguments)
          when "issue_update"
            update_issue(arguments)
          when "insert_bulk_update"
            bulk_update_issues(arguments)
          when "issue_delete"
            delete_issue(arguments)
          when "issue_relation_create"
            create_issue_relation(arguments)
          when "issue_relation_delete"
            delete_issue_relation(arguments)
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
          project = args['project_id'].present? ? Project.visible.find(args['project_id']) : nil
          scope = Issue.visible

          # Basic filters
          scope = scope.where(project_id: project.id) if project
          scope = scope.where(status_id: args['status_id']) if args['status_id']
          scope = scope.where(assigned_to_id: args['assigned_to_id']) if args['assigned_to_id']
          scope = scope.where(author_id: args['author_id']) if args['author_id']
          scope = scope.where(tracker_id: args['tracker_id']) if args['tracker_id']
          scope = scope.where(priority_id: args['priority_id']) if args['priority_id']
          scope = scope.where(category_id: args['category_id']) if args['category_id']
          scope = scope.where(fixed_version_id: args['fixed_version_id']) if args['fixed_version_id']
          scope = scope.where(parent_id: args['parent_id']) if args['parent_id']
          scope = apply_named_issue_filters(scope, args, project)
          scope = apply_boolean_issue_filters(scope, args)
          scope = apply_relation_issue_filters(scope, args)

          # Stage filter (requires advanced_issue_status plugin)
          if args.key?('stage') && IssueStatus.column_names.include?('stage')
            stage_val = args['stage'].to_i
            # stage 컬럼이 NULL인 레코드도 STAGE_NEW(0)로 취급
            if stage_val == 0
              stage_status_ids = IssueStatus.where(stage: [0, nil]).pluck(:id)
            else
              stage_status_ids = IssueStatus.where(stage: stage_val).pluck(:id)
            end
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
            scope = scope.where("#{Issue.table_name}.updated_on >= ?", parse_filter_date(args['updated_since'], 'updated_since'))
          end
          if args['created_since']
            scope = scope.where("#{Issue.table_name}.created_on >= ?", parse_filter_date(args['created_since'], 'created_since'))
          end
          if args['due_date_from']
            scope = scope.where("#{Issue.table_name}.due_date >= ?", parse_filter_date(args['due_date_from'], 'due_date_from'))
          end
          if args['due_date_to']
            scope = scope.where("#{Issue.table_name}.due_date <= ?", parse_filter_date(args['due_date_to'], 'due_date_to'))
          end

          scope = scope.includes(:project, :status, :tracker, :priority, :assigned_to, :author, :fixed_version, :parent)

          # Sorting
          scope = apply_sort(scope, args['sort'])

          build_issue_list_response(scope, args, chatbot: chatbot)
        end

        # ─── Get ────────────────────────────────────────────

        def get_issue(args, chatbot: false)
          issue = Issue.visible.find(args['id'])
          result = format_issue_details(issue, chatbot: chatbot)

          if args['include_journals']
            result[:journals] = issue.visible_journals_with_index(User.current).map do |journal|
              {
                id: journal.id,
                user: journal.user ? { id: journal.user.id, name: journal.user.name } : nil,
                notes: journal.notes,
                created_on: journal.created_on&.iso8601,
                details: journal.visible_details(User.current).map do |detail|
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

        def get_issue_relations(args, chatbot: false)
          issue = Issue.visible.find(args['issue_id'])
          relations = visible_issue_relations(issue)

          if args['relation_type'].present?
            relation_type = normalize_relation_type(args['relation_type'], 'relation_type')
            relations = relations.select { |relation| relation.relation_type_for(issue) == relation_type }
          end

          build_issue_relations_payload(issue, relations, chatbot: chatbot)
        rescue ActiveRecord::RecordNotFound
          { error: "Issue not found" }
        end

        # ─── Create ─────────────────────────────────────────

        def create_issue(args)
          project = Project.visible.find(args['project_id'])
          return { error: "Not authorized to create issues in this project" } unless User.current.allowed_to?(:add_issues, project)

          issue = Issue.new
          issue.project = project
          issue.author = User.current
          issue.safe_attributes = issue_safe_attributes(args, include_tracker: true)

          if issue.save
            format_issue_details(issue)
          else
            { error: "Failed to create issue", validation_errors: issue.errors.full_messages }
          end
        rescue ActiveRecord::RecordNotFound
          { error: "Project not found" }
        end

        # ─── Update ─────────────────────────────────────────

        def update_issue(args)
          issue = Issue.visible.find(args['id'])
          return { error: "Not authorized to edit this issue" } unless issue.editable?(User.current)

          initialize_issue_journal(issue, args['notes'])
          issue.safe_attributes = issue_safe_attributes(args)

          if issue.save
            format_issue_details(issue)
          else
            { error: "Failed to update issue", validation_errors: issue.errors.full_messages }
          end
        rescue ActiveRecord::RecordNotFound
          { error: "Issue not found" }
        end

        def bulk_update_issues(args)
          issue_ids = normalize_issue_ids(args['issue_ids'])
          return { error: "issue_ids must contain at least one valid issue ID" } if issue_ids.empty?
          return { error: "No update fields were provided for bulk update" } unless issue_update_fields_present?(args)

          allow_partial_success = truthy_argument?(args['allow_partial_success'])
          issues_by_id = Issue.visible.where(id: issue_ids).index_by(&:id)
          failures = []
          updated_ids = []

          missing_ids = issue_ids - issues_by_id.keys
          missing_ids.each do |id|
            failures << { id: id, error: "Issue not found or not visible" }
          end

          if failures.any? && !allow_partial_success
            return bulk_update_failure_payload(issue_ids, failures, atomic: true)
          end

          if allow_partial_success
            issue_ids.each do |id|
              issue = issues_by_id[id]
              next unless issue

              unless issue.editable?(User.current)
                failures << { id: issue.id, error: "Not authorized to edit this issue" }
                next
              end

              initialize_issue_journal(issue, args['notes'])
              issue.safe_attributes = issue_safe_attributes(args)
              if issue.save
                updated_ids << issue.id
              else
                failures << { id: issue.id, error: "Failed to update issue", validation_errors: issue.errors.full_messages }
              end
            end
          else
            failure = nil

            Issue.transaction do
              issue_ids.each do |id|
                issue = issues_by_id[id]
                next unless issue

                unless issue.editable?(User.current)
                  failure = { id: issue.id, error: "Not authorized to edit this issue" }
                  raise ActiveRecord::Rollback
                end

                initialize_issue_journal(issue, args['notes'])
                issue.safe_attributes = issue_safe_attributes(args)
                unless issue.save
                  failure = { id: issue.id, error: "Failed to update issue", validation_errors: issue.errors.full_messages }
                  raise ActiveRecord::Rollback
                end
                updated_ids << issue.id
              end
            end

            if failure
              failures << failure
              updated_ids = []
              return bulk_update_failure_payload(issue_ids, failures, atomic: true)
            end
          end

          if updated_ids.empty?
            return bulk_update_failure_payload(issue_ids, failures, atomic: !allow_partial_success)
          end

          updated_issues = Issue.visible
            .where(id: updated_ids)
            .includes(:status, :tracker, :priority, :assigned_to, :fixed_version)
            .index_by(&:id)

          {
            success: failures.empty?,
            partial_success: failures.any?,
            message: failures.any? ? "Updated #{updated_ids.size} issues, #{failures.size} failed" : "Updated #{updated_ids.size} issues",
            requested_issue_ids: issue_ids,
            updated_issue_ids: updated_ids,
            updated_count: updated_ids.size,
            failed_count: failures.size,
            issues: updated_ids.filter_map { |id| updated_issues[id] && format_issue_details(updated_issues[id], chatbot: true) },
            failed: failures
          }
        end

        # ─── Delete ─────────────────────────────────────────

        def delete_issue(args)
          issue = Issue.visible.find(args['id'])
          return { error: "Not authorized to delete this issue" } unless issue.deletable?(User.current)

          if issue.destroy
            { success: true, message: "Issue ##{args['id']} deleted" }
          else
            { error: "Failed to delete issue", validation_errors: issue.errors.full_messages }
          end
        rescue ActiveRecord::RecordNotFound
          { error: "Issue not found" }
        end

        def create_issue_relation(args)
          issue = Issue.visible.find(args['issue_id'])
          return { error: "Not authorized to manage issue relations" } unless User.current.allowed_to?(:manage_issue_relations, issue.project)

          relation = IssueRelation.new
          relation.issue_from = issue
          relation.safe_attributes = {
            'issue_to_id' => args['related_issue_id'],
            'relation_type' => normalize_relation_type(args['relation_type'], 'relation_type'),
            'delay' => nullable_id_value(args, 'delay')
          }.compact
          relation.init_journals(User.current)

          if relation.save
            format_issue_relation(relation, issue)
          else
            { error: "Failed to create issue relation", validation_errors: relation.errors.full_messages }
          end
        rescue ActiveRecord::RecordNotFound
          { error: "Issue not found" }
        end

        def delete_issue_relation(args)
          relation = IssueRelation.find(args['id'])
          return { error: "Not authorized to manage issue relations" } unless relation.deletable?(User.current)

          issue = relation.issue_from || relation.issue_to
          relation.init_journals(User.current)
          summary = issue ? format_issue_relation(relation, issue) : { id: relation.id }
          relation.destroy

          { success: true, relation: summary, message: "Issue relation ##{args['id']} deleted" }
        rescue ActiveRecord::RecordNotFound
          { error: "Issue relation not found" }
        end

        # ─── Children Summary ───────────────────────────────

        def children_summary(args, chatbot: false)
          data = RedmineTxMilestone::SummaryService.children_summary(args['parent_id'])
          return data if data[:error]
          slim_children_summary(data)
        end

        # ─── Version Overview ───────────────────────────────

        def version_overview(args, chatbot: false)
          data = RedmineTxMilestone::SummaryService.version_overview(args['version_id'])
          return data if data[:error]
          slim_version_overview(data)
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

        def build_issue_list_response(scope, args, chatbot: false)
          fetch_all = truthy_argument?(args['fetch_all'])
          total = scope.count
          max_per_page = chatbot ? 25 : 100
          default_per_page = chatbot ? 10 : 25
          fetch_all_cap = chatbot ? 50 : 100

          page = fetch_all ? 1 : [args['page'].to_i, 1].max
          per_page_limit = fetch_all ? fetch_all_cap : max_per_page
          per_page = args['per_page'].to_i > 0 ? [[args['per_page'].to_i, 1].max, per_page_limit].min : (fetch_all ? fetch_all_cap : default_per_page)
          offset = fetch_all ? 0 : (page - 1) * per_page
          items = scope.offset(offset).limit(per_page).to_a
          preload_issue_list_context(items) if chatbot
          total_pages = (total.to_f / per_page).ceil
          has_more = total > offset + items.size

          result = {
            items: items.map { |issue| chatbot ? format_issue_list_item(issue) : format_issue_details(issue) },
            pagination: {
              page: page,
              per_page: per_page,
              total_count: total,
              total_pages: total_pages
            },
            returned_count: items.size,
            has_more: has_more,
            detail_level: chatbot ? 'summary' : 'detail'
          }

          result[:next_page] = page + 1 if has_more
          notice = issue_list_notice(total: total, returned_count: items.size, page: page, total_pages: total_pages, has_more: has_more, fetch_all: fetch_all)
          result[:notice] = notice if notice
          if chatbot
            result[:next_step_hint] = "issue_list is for search and browsing. After you identify one exact issue, use issue_get(id) for detailed fields, parent info, current relations, and journals."
          end
          result
        end

        def issue_list_notice(total:, returned_count:, page:, total_pages:, has_more:, fetch_all:)
          return nil unless has_more

          if fetch_all
            "Showing first #{returned_count} of #{total} matching issues. Narrow the filters or continue with page: 2."
          else
            "Showing page #{page} of #{total_pages}. More matching issues remain. Use fetch_all: true for a capped full list or page: #{page + 1} to continue."
          end
        end

        def apply_named_issue_filters(scope, args, project)
          scope = apply_named_id_filter(scope, args['status_name'], 'status_id', IssueStatus.sorted)
          scope = apply_named_id_filter(scope, args['assigned_to_name'], 'assigned_to_id', searchable_users)
          scope = apply_named_id_filter(scope, args['author_name'], 'author_id', searchable_users)
          scope = apply_named_id_filter(scope, args['tracker_name'], 'tracker_id', Tracker.sorted)
          scope = apply_named_id_filter(scope, args['priority_name'], 'priority_id', IssuePriority.active)
          scope = apply_named_id_filter(scope, args['category_name'], 'category_id', searchable_categories(project))
          scope = apply_named_id_filter(scope, args['fixed_version_name'], 'fixed_version_id', searchable_versions(project))
          scope
        end

        def apply_named_id_filter(scope, query, column_name, records)
          return scope unless query.present?

          ids = resolve_name_filter_ids(records, query)
          ids.any? ? scope.where(column_name => ids) : scope.none
        end

        def apply_boolean_issue_filters(scope, args)
          scope = apply_null_filter(scope, args, 'is_unassigned', 'assigned_to_id')
          scope = apply_null_filter(scope, args, 'has_no_category', 'category_id')
          scope = apply_null_filter(scope, args, 'has_no_fixed_version', 'fixed_version_id')
          scope = apply_null_filter(scope, args, 'is_root_issue', 'parent_id')
          scope = apply_null_filter(scope, args, 'has_no_due_date', 'due_date')
          scope = apply_has_relations_filter(scope, args)
          scope
        end

        def apply_null_filter(scope, args, key, column_name)
          return scope unless args.key?(key)

          truthy_argument?(args[key]) ? scope.where(column_name => nil) : scope.where.not(column_name => nil)
        end

        def apply_has_relations_filter(scope, args)
          return scope unless args.key?('has_relations')

          relation_sql = "#{Issue.table_name}.id IN (SELECT issue_from_id FROM #{IssueRelation.table_name}) OR " \
            "#{Issue.table_name}.id IN (SELECT issue_to_id FROM #{IssueRelation.table_name})"

          truthy_argument?(args['has_relations']) ? scope.where(relation_sql) : scope.where("NOT (#{relation_sql})")
        end

        def apply_relation_issue_filters(scope, args)
          return scope unless args['related_to_id']

          issue = Issue.visible.find(args['related_to_id'])
          related_ids = visible_issue_relations(issue)
            .filter_map { |relation| relation.other_issue(issue)&.id }
            .uniq

          related_ids.any? ? scope.where(id: related_ids) : scope.none
        end

        def parse_filter_date(value, field_name)
          return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

          raw = value.to_s.strip
          raise ArgumentError, "#{field_name} cannot be blank" if raw.empty?

          normalized = raw.downcase
          today = Date.current
          return today if %w[today 오늘].include?(normalized)
          return today - 1 if %w[yesterday 어제].include?(normalized)
          return today + 1 if %w[tomorrow 내일].include?(normalized)
          return today - normalized[/\d+/].to_i if normalized.match?(/\A\d+\s*(?:days?\s*ago|일\s*전)\z/)
          return today + normalized[/\d+/].to_i if normalized.match?(/\A(?:in\s*)?\d+\s*(?:days?|일)\s*(?:later|후)?\z/)

          if normalized.match?(/\A\d{4}[-\/.]\d{1,2}[-\/.]\d{1,2}\z/)
            year, month, day = normalized.tr('/.', '-').split('-').map(&:to_i)
            return Date.new(year, month, day)
          end

          raise ArgumentError, "#{field_name} must be YYYY-MM-DD or one of today/yesterday/tomorrow/오늘/어제/내일"
        rescue Date::Error => e
          raise ArgumentError, "#{field_name} is not a valid date: #{e.message}"
        end

        def searchable_users
          scope = User
          scope = scope.active if scope.respond_to?(:active)
          scope.to_a
        end

        def searchable_categories(project)
          project ? project.issue_categories.to_a : IssueCategory.all.to_a
        end

        def searchable_versions(project)
          if project
            project.versions.visible.to_a
          elsif Version.respond_to?(:visible)
            Version.visible.to_a
          else
            Version.all.to_a
          end
        end

        def resolve_name_filter_ids(records, query)
          normalized_query = normalize_search_term(query)
          return [] if normalized_query.empty?

          Array(records).filter_map do |record|
            next unless record.respond_to?(:id)
            next unless searchable_terms_for_record(record).any? { |term| normalize_search_term(term).include?(normalized_query) }

            record.id
          end.uniq
        end

        def searchable_terms_for_record(record)
          terms = []
          %i[name firstname lastname login mail identifier].each do |method_name|
            next unless record.respond_to?(method_name)

            value = record.public_send(method_name)
            terms << value if value.present?
          end

          if record.respond_to?(:firstname) && record.respond_to?(:lastname)
            firstname = record.firstname.to_s
            lastname = record.lastname.to_s
            if firstname.present? || lastname.present?
              terms << "#{firstname} #{lastname}".strip
              terms << "#{lastname} #{firstname}".strip
              terms << "#{firstname}#{lastname}"
              terms << "#{lastname}#{firstname}"
            end
          end

          terms.uniq
        end

        def normalize_search_term(value)
          value.to_s.downcase.gsub(/\s+/, '')
        end

        def preload_issue_list_context(items)
          return if items.empty?
          return unless Issue.respond_to?(:load_visible_relations)

          Issue.load_visible_relations(items, User.current)
        rescue => e
          Rails.logger.warn("Issue.load_visible_relations failed in issue_list: #{e.class}: #{e.message}") if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        end

        def visible_issue_relations(issue)
          Array(issue.relations).select do |relation|
            other_issue = relation.other_issue(issue)
            other_issue && (!other_issue.respond_to?(:visible?) || other_issue.visible?(User.current))
          end
        end

        def build_issue_relations_payload(issue, relations, chatbot: false)
          limited_relations = chatbot ? relations.first(20) : relations
          payload = {
            detail_level: 'relations',
            issue: {
              id: issue.id,
              subject: issue.subject
            },
            relation_count: relations.size,
            relations: limited_relations.map { |relation| format_issue_relation(relation, issue) }
          }
          if chatbot && relations.size > limited_relations.size
            payload[:notice] = "Showing #{limited_relations.size} of #{relations.size} relations. Use issue_get for the full issue context."
          end
          payload
        end

        def format_issue_list_item(issue)
          relations = visible_issue_relations(issue)

          {
            detail_level: 'summary',
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
            parent_issue_id: issue.parent_id,
            has_relations: relations.any?,
            relation_count: relations.size,
            relation_summary: issue_relation_summary(issue, relations),
            start_date: issue.start_date&.iso8601,
            due_date: issue.due_date&.iso8601,
            estimated_hours: issue.estimated_hours,
            spent_hours: issue.spent_hours,
            done_ratio: issue.done_ratio,
            worker: issue.respond_to?(:worker) && issue.worker ? issue.worker.name : nil,
          }.merge(issue_tip_fields(issue))
        end

        def format_issue_relation(relation, issue)
          other_issue = relation.other_issue(issue)

          {
            id: relation.id,
            relation_type: relation.relation_type_for(issue),
            delay: relation.respond_to?(:delay) ? relation.delay : nil,
            other_issue: other_issue ? {
              id: other_issue.id,
              subject: other_issue.subject,
              tracker: other_issue.tracker ? other_issue.tracker.name : nil,
              status: other_issue.status ? other_issue.status.name : nil,
              is_closed: other_issue.status ? other_issue.status.is_closed? : nil,
              assigned_to: other_issue.assigned_to ? other_issue.assigned_to.name : nil,
              start_date: other_issue.start_date&.iso8601,
              due_date: other_issue.due_date&.iso8601,
              done_ratio: other_issue.done_ratio
            } : nil
          }
        end

        def issue_relation_summary(issue, relations = nil)
          relation_types = Array(relations || visible_issue_relations(issue)).map { |relation| relation.relation_type_for(issue) }

          {
            total: relation_types.size,
            types: relation_types.uniq.sort,
            has_predecessor: relation_types.include?(IssueRelation::TYPE_FOLLOWS),
            has_successor: relation_types.include?(IssueRelation::TYPE_PRECEDES),
            has_blocker: relation_types.include?(IssueRelation::TYPE_BLOCKED),
            blocks_others: relation_types.include?(IssueRelation::TYPE_BLOCKS)
          }
        end

        def normalize_relation_type(value, field_name)
          normalized = value.to_s.strip.downcase.tr(' ', '_')
          aliases = {
            'related' => IssueRelation::TYPE_RELATES,
            'blocked_by' => IssueRelation::TYPE_BLOCKED,
            'duplicated_by' => IssueRelation::TYPE_DUPLICATED
          }
          normalized = aliases.fetch(normalized, normalized)

          return normalized if IssueRelation::TYPES.key?(normalized)

          supported = IssueRelation::TYPES.keys.join(', ')
          raise ArgumentError, "#{field_name} must be one of: #{supported}"
        end

        def issue_safe_attributes(args, include_tracker: false)
          attrs = {}
          attrs['tracker_id'] = args['tracker_id'] if include_tracker && args.key?('tracker_id')
          attrs['subject'] = args['subject'] if args.key?('subject') && !args['subject'].nil?
          attrs['description'] = nullable_string_value(args, 'description') if args.key?('description')
          attrs['status_id'] = args['status_id'] if args.key?('status_id') && !args['status_id'].nil?
          attrs['priority_id'] = args['priority_id'] if args.key?('priority_id') && !args['priority_id'].nil?
          attrs['assigned_to_id'] = nullable_id_value(args, 'assigned_to_id') if args.key?('assigned_to_id')
          attrs['category_id'] = nullable_id_value(args, 'category_id') if args.key?('category_id')
          attrs['fixed_version_id'] = nullable_id_value(args, 'fixed_version_id') if args.key?('fixed_version_id')
          attrs['parent_issue_id'] = nullable_id_value(args, 'parent_issue_id') if args.key?('parent_issue_id')
          attrs['start_date'] = nullable_date_value(args, 'start_date') if args.key?('start_date')
          attrs['due_date'] = nullable_date_value(args, 'due_date') if args.key?('due_date')
          attrs['estimated_hours'] = nullable_number_value(args, 'estimated_hours') if args.key?('estimated_hours')
          attrs['done_ratio'] = args['done_ratio'] if args.key?('done_ratio') && !args['done_ratio'].nil?
          attrs
        end

        def assign_issue_update_attributes(issue, args)
          attrs = issue_safe_attributes(args)
          issue.subject = attrs['subject'] if attrs.key?('subject')
          issue.description = attrs['description'] if attrs.key?('description')
          issue.status_id = attrs['status_id'] if attrs.key?('status_id')
          issue.priority_id = attrs['priority_id'] if attrs.key?('priority_id')
          issue.assigned_to_id = attrs['assigned_to_id'] if attrs.key?('assigned_to_id')
          issue.category_id = attrs['category_id'] if attrs.key?('category_id')
          issue.fixed_version_id = attrs['fixed_version_id'] if attrs.key?('fixed_version_id')
          issue.parent_issue_id = attrs['parent_issue_id'] if attrs.key?('parent_issue_id')
          issue.start_date = attrs['start_date'] if attrs.key?('start_date')
          issue.due_date = attrs['due_date'] if attrs.key?('due_date')
          issue.estimated_hours = attrs['estimated_hours'] if attrs.key?('estimated_hours')
          issue.done_ratio = attrs['done_ratio'] if attrs.key?('done_ratio')
          issue.notes = args['notes'] if args['notes'].present? && issue.respond_to?(:notes=)
        end

        def initialize_issue_journal(issue, notes)
          if notes.present?
            issue.init_journal(User.current, notes.to_s)
          else
            issue.init_journal(User.current)
          end
        end

        def issue_update_fields_present?(args)
          %w[
            subject description status_id priority_id assigned_to_id category_id
            fixed_version_id parent_issue_id start_date due_date estimated_hours
            done_ratio notes
          ].any? { |key| args.key?(key) }
        end

        def normalize_issue_ids(issue_ids)
          Array(issue_ids).filter_map do |value|
            id = value.to_i
            id if id.positive?
          end.uniq
        end

        def truthy_argument?(value)
          case value
          when true, 1, '1', 'true', 'TRUE', 'yes', 'YES', 'y', 'Y', 'on', 'ON'
            true
          else
            false
          end
        end

        def nullable_string_value(args, key)
          value = args[key]
          return nil if value.nil? || value == ''

          value.to_s
        end

        def nullable_id_value(args, key)
          value = args[key]
          return nil if value.nil? || value == ''

          value.to_i
        end

        def nullable_date_value(args, key)
          value = args[key]
          return nil if value.nil? || value == ''

          Date.parse(value)
        end

        def nullable_number_value(args, key)
          value = args[key]
          return nil if value.nil? || value == ''

          value
        end

        def bulk_update_failure_payload(issue_ids, failures, atomic:)
          {
            error: atomic ? "Bulk update failed; no changes were applied" : "No issues were updated",
            requested_issue_ids: issue_ids,
            updated_issue_ids: [],
            updated_count: 0,
            failed_count: failures.size,
            failed: failures
          }
        end

        # ─── Token reduction: SummaryService → LLM-friendly ─

        # Flatten nested hashes to scalars, drop closed items and verbose fields
        def slim_children_summary(data)
          data[:parent] = slim_issue(data[:parent])

          data[:children_by_stage] = data[:children_by_stage].each_with_object({}) do |(stage, children), h|
            slimmed = children.reject { |c| c[:is_closed] }
                              .map { |c| slim_child(c) }
            h[stage] = slimmed if slimmed.any?
          end

          data[:alerts] = data[:alerts].map { |a| a.except(:assigned_to) }
          data[:summary].delete(:spent_hours)
          data
        end

        def slim_version_overview(data)
          v = data[:version]
          data[:version] = {
            id: v[:id], name: v[:name], status: v[:status],
            due_date: v[:due_date], done_ratio: v[:done_ratio],
            overdue: v[:overdue], total_issues: v[:total_issues]
          }

          data[:parent_issues] = data[:parent_issues]
            .reject { |p| p[:is_closed] }
            .map { |p| slim_parent_summary(p) }

          if data[:parent_issues].size > 30
            data[:notice] = "Showing 30 of #{data[:parent_issues].size} parent issues (sorted by priority). Use issue_children_summary for details on specific parents."
            data[:parent_issues] = data[:parent_issues].first(30)
          end

          data[:alerts] = data[:alerts].map { |a| a.except(:overdue_issues) }
          data
        end

        def slim_issue(h)
          {
            id: h[:id], subject: h[:subject],
            tracker: h.dig(:tracker, :name), status: h.dig(:status, :name),
            stage: h.dig(:status, :stage_name), priority: h.dig(:priority, :name),
            assigned_to: h.dig(:assigned_to, :name), fixed_version: h.dig(:fixed_version, :name),
            start_date: h[:start_date], due_date: h[:due_date],
            estimated_hours: h[:estimated_hours], spent_hours: h[:spent_hours],
            done_ratio: h[:done_ratio],
            tip_code: h.dig(:tip, :code)
          }
        end

        def slim_child(h)
          {
            id: h[:id], subject: h[:subject],
            tracker: h.dig(:tracker, :name), status: h.dig(:status, :name),
            stage: h[:stage], assigned_to: h.dig(:assigned_to, :name),
            done_ratio: h[:done_ratio], due_date: h[:due_date],
            is_overdue: h[:is_overdue], estimated_hours: h[:estimated_hours],
            tip_code: h.dig(:tip, :code)
          }
        end

        def slim_parent_summary(h)
          s = h[:children_stats] || {}
          {
            id: h[:id], subject: h[:subject],
            tracker: h.dig(:tracker, :name), assigned_to: h.dig(:assigned_to, :name),
            stage: h[:stage], done_ratio: h[:done_ratio], due_date: h[:due_date],
            children_total: s[:total], children_completed: s[:completed],
            children_in_progress: s[:in_progress], children_overdue: s[:overdue],
            estimated_hours: s[:estimated_hours], tip_code: h.dig(:tip, :code)
          }
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
            estimated_hours: child.estimated_hours
          }.merge(issue_tip_fields(child))
        end

        def format_issue_details(issue, chatbot: false)
          relations = visible_issue_relations(issue)
          limited_relations = chatbot ? relations.first(20) : relations

          if chatbot
            result = {
              detail_level: 'detail',
              id: issue.id,
              subject: issue.subject,
              description: issue.description,
              project: issue.project ? {
                id: issue.project.id,
                name: issue.project.name,
                identifier: issue.project.identifier
              } : nil,
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
              },
              priority: issue.priority ? {
                id: issue.priority.id,
                name: issue.priority.name
              } : nil,
              author: issue.author ? {
                id: issue.author.id,
                name: issue.author.name
              } : nil,
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
              relation_count: relations.size,
              relations: limited_relations.map { |relation| format_issue_relation(relation, issue) },
              start_date: issue.start_date&.iso8601,
              due_date: issue.due_date&.iso8601,
              estimated_hours: issue.estimated_hours,
              spent_hours: issue.spent_hours,
              done_ratio: issue.done_ratio,
              worker: issue.respond_to?(:worker) && issue.worker ? issue.worker.name : nil,
              created_on: issue.created_on&.iso8601,
              updated_on: issue.updated_on&.iso8601,
              closed_on: issue.closed_on&.iso8601
            }.merge(issue_tip_fields(issue))
            if relations.size > limited_relations.size
              result[:relations_notice] = "Showing #{limited_relations.size} of #{relations.size} relations."
            end
            return result
          end

          {
            detail_level: 'detail',
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
            relation_count: relations.size,
            relations: limited_relations.map { |relation| format_issue_relation(relation, issue) },
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
