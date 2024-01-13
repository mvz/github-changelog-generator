# frozen_string_literal: true

module GitHubChangelogGenerator
  class Generator
    # Fetch event for issues and pull requests
    # @return [Array] array of fetched issues
    def fetch_events_for_issues_and_pr
      print "Fetching events for issues and PR: 0/#{@issues.count + @pull_requests.count}\r" if options[:verbose]

      # Async fetching events:
      @fetcher.fetch_events_async(@issues + @pull_requests)
    end

    # Async fetching of all tags dates
    def fetch_tags_dates(tags)
      print "Fetching tag dates...\r" if options[:verbose]
      i = 0
      tags.each do |tag|
        get_time_of_tag(tag)
        i += 1
      end
      puts "Fetching tags dates: #{i}/#{tags.count}" if options[:verbose]
    end

    # Find correct closed dates, if issues was closed by commits
    def detect_actual_closed_dates(issues)
      print "Fetching closed dates for issues...\r" if options[:verbose]

      i = 0
      issues.each do |issue|
        find_closed_date_by_commit(issue)
        i += 1
      end
      puts "Fetching closed dates for issues: #{i}/#{issues.count}" if options[:verbose]
    end

    # Adds a key "first_occurring_tag" to each PR with a value of the oldest
    # tag that a PR's merge commit occurs in in the git history. This should
    # indicate the release of each PR by git's history regardless of dates and
    # divergent branches.
    #
    # @param [Array] tags The tags sorted by time, newest to oldest.
    # @param [Array] prs The PRs to discover the tags of.
    # @return [Nil] No return; PRs are updated in-place.
    def add_first_occurring_tag_to_prs(tags, prs)
      total = prs.count

      prs_left = associate_tagged_or_release_branch_prs(tags, prs, total)

      Helper.log.info "Associating PRs with tags: #{total}/#{total}"

      prs_left
    end

    # Associate merged PRs by the merge SHA contained in each tag. If the
    # merge_commit_sha is not found in any tag's history, try to associate with
    # the release branch instead.
    #
    # @param [Array] tags The tags sorted by time, newest to oldest.
    # @param [Array] prs The PRs to associate.
    # @return [Array] PRs without their merge_commit_sha in a tag.
    def associate_tagged_or_release_branch_prs(tags, prs, total)
      @fetcher.fetch_tag_shas(tags)

      i = 0
      prs.reject do |pr|
        found = associate_tagged_or_release_branch_pr(tags, pr)

        if found
          i += 1
          print("Associating PRs with tags: #{i}/#{total}\r") if @options[:verbose]
        end
        found
      end
    end

    def associate_tagged_or_release_branch_pr(tags, pull_request)
      found = false
      if (merged_sha = find_merged_sha_for_pull_request(pull_request))
        found = associate_pr_by_commit_sha(tags, pull_request, merged_sha)

        unless found
          # The PR was not found in the list of tags by its merge commit and
          # not found in any specified release branch. Fall back to rebased
          # commit comment.
          @fetcher.fetch_comments_async([pull_request])
          found = associate_rebase_comment_pr(tags, pull_request)
        end
      else
        # Either there were no events or no merged event. GitHub's api can be
        # weird like that apparently. Check for a rebased comment before erroring.
        @fetcher.fetch_comments_async([pull_request])
        rebased_found = associate_rebase_comment_pr(tags, pull_request)
        raise StandardError, "No merge sha found for PR #{pull_request['number']} via the GitHub API" unless rebased_found

        found = true
      end
      found
    end

    def associate_rebase_comment_pr(tags, pull_request)
      found = false
      if (rebased_sha = find_rebase_comment_sha_for_pull_request(pull_request))
        found = associate_pr_by_commit_sha(tags, pull_request, rebased_sha)
        found or raise StandardError, "PR #{pull_request['number']} has a rebased SHA comment but that SHA was not found in the release branch or any tags"
      else
        puts "Warning: PR #{pull_request['number']} merge commit was not found in the release branch or tagged git history and no rebased SHA comment was found"
      end
      found
    end

    def associate_pr_by_commit_sha(tags, pull_request, commit_sha)
      # Iterate tags.reverse (oldest to newest) to find first tag of PR.
      if (oldest_tag = tags.reverse.find { |tag| tag["shas_in_tag"].include?(commit_sha) })
        pull_request["first_occurring_tag"] = oldest_tag["name"]
        true
      else
        sha_in_release_branch?(commit_sha)
      end
    end

    def find_merged_sha_for_pull_request(pull_request)
      # XXX Wish I could use merge_commit_sha, but gcg doesn't currently
      # fetch that. See
      # https://developer.github.com/v3/pulls/#get-a-single-pull-request vs.
      # https://developer.github.com/v3/pulls/#list-pull-requests
      event = pull_request["events"]&.find { |e| e["event"] == "merged" }
      event["commit_id"] if event
    end

    def find_rebase_comment_sha_for_pull_request(pull_request)
      return unless pull_request["comments"]

      rebased_comment = pull_request["comments"].reverse.find { |c| c["body"].match(%r{rebased commit: ([0-9a-f]{40})}i) }

      rebased_comment["body"].match(%r{rebased commit: ([0-9a-f]{40})}i)[1] if rebased_comment
    end

    # Fill :actual_date parameter of specified issue by closed date of the commit, if it was closed by commit.
    # @param [Hash] issue
    def find_closed_date_by_commit(issue)
      return if issue["events"].nil?

      # if it's PR -> then find "merged event", in case of usual issue -> found closed date
      compare_string = issue["merged_at"].nil? ? "closed" : "merged"
      # reverse! - to find latest closed event. (event goes in date order)
      issue["events"].reverse!.each do |event|
        if event["event"] == compare_string
          set_date_from_event(event, issue)
          break
        end
      end
      # TODO: assert issues, that remain without 'actual_date' hash for some reason.
    end

    # Set closed date from this issue
    #
    # @param [Hash] event
    # @param [Hash] issue
    def set_date_from_event(event, issue)
      if event["commit_id"].nil?
        issue["actual_date"] = issue["closed_at"]
        return
      end

      commit = @fetcher.fetch_commit(event["commit_id"])
      issue["actual_date"] = commit["commit"]["author"]["date"]

      # issue['actual_date'] = commit['author']['date']
    rescue StandardError
      puts "Warning: Can't fetch commit #{event['commit_id']}. It is probably referenced from another repo."
      issue["actual_date"] = issue["closed_at"]
    end

    private

    # Detect if a sha occurs in the --release-branch. Uses the github repo
    # default branch if not specified.
    #
    # @param [String] sha SHA to check.
    # @return [Boolean] True if SHA is in the branch git history.
    def sha_in_release_branch?(sha)
      branch = @options[:release_branch] || @fetcher.default_branch
      @fetcher.commits_in_branch(branch).include?(sha)
    end
  end
end
