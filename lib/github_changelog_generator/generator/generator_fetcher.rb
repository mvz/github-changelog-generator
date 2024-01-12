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
    # If the merge commit is not found in any tag's history, associates with the
    # release branch instead.
    #
    # @param [Array] tags The tags sorted by time, newest to oldest.
    # @param [Array] prs The PRs to discover the tags of.
    # @return [Array] PRs that could not be associated with either a tag or release branch
    def add_first_occurring_tag_to_prs(tags, prs)
      total = prs.count

      @fetcher.fetch_tag_shas(tags)
      i = 0
      prs_left = prs.reject do |pr|
        found = associate_tagged_or_release_branch_pr(tags, pr)

        if found
          i += 1
          print("Associating PRs with tags: #{i}/#{total}\r") if @options[:verbose]
        end
        found
      end

      Helper.log.info "Associating PRs with tags: #{total}/#{total}"

      prs_left
    end

    # Associate a merged PR by finding the merge or rebase SHA in each tag's
    # contained commit SHAs. If the SHA is not found in any tag's history, try
    # to associate with the release branch instead.
    #
    # @param [Array] tags The tags sorted by time, newest to oldest.
    # @param [Array] pull_request The PR to discover the tags of.
    # @return [boolean] Whether the PR could be associated with either a tag or the release branch
    def associate_tagged_or_release_branch_pr(tags, pull_request)
      found = false

      merged_sha = find_merged_sha_for_pull_request(pull_request)

      if merged_sha
        found = associate_pr_by_commit_sha(tags, pull_request, merged_sha)
        return found if found
      end

      # The PR was not found in the list of tags by its merge commit and not
      # found in any specified release branch, or no merged event could be
      # find. Either way, fall back to rebased commit comment.
      rebased_sha = find_rebase_comment_sha_for_pull_request(pull_request)

      if rebased_sha
        found = associate_pr_by_commit_sha(tags, pull_request, rebased_sha)
        return found if found

        raise StandardError, "PR #{pull_request['number']} has a rebased SHA comment but that SHA was not found in the release branch or any tags"
      elsif merged_sha
        puts "Warning: PR #{pull_request['number']} merge commit was not found in the release branch or tagged git history and no rebased SHA comment was found"
      else
        # Either there were no events or no merged event. GitHub's api can be
        # weird like that apparently.
        #
        # Looking for a rebased comment did not help either. Error out.
        raise StandardError, "No merge sha found for PR #{pull_request['number']} via the GitHub API"
      end

      found
    end

    # Associate a merged PR by seeking the given SHA in each tag's history. If
    # the SHA is not found in any tag's history, try to associate with the
    # release branch instead.
    #
    # @param [Array] tags The tags sorted by time, newest to oldest.
    # @param [Hash] pull_request The PR to associate.
    # @return [boolean] Whether the PR could be associated
    def associate_pr_by_commit_sha(tags, pull_request, commit_sha)
      # Iterate tags.reverse (oldest to newest) to find first tag of PR.
      if (oldest_tag = tags.reverse.find { |tag| tag["shas_in_tag"].include?(commit_sha) })
        pull_request["first_occurring_tag"] = oldest_tag["name"]
        true
      else
        sha_in_release_branch?(commit_sha)
      end
    end

    # Find a merged PR's merge commit SHA in the PR's merge event.
    #
    # @param [Hash] pull_request The PR to find the merge commit sha for.
    # @return [String] The found commit sha
    def find_merged_sha_for_pull_request(pull_request)
      # XXX Wish I could use merge_commit_sha, but gcg doesn't currently
      # fetch that. See
      # https://developer.github.com/v3/pulls/#get-a-single-pull-request vs.
      # https://developer.github.com/v3/pulls/#list-pull-requests
      event = pull_request["events"]&.find { |e| e["event"] == "merged" }
      event["commit_id"] if event
    end

    # Find a merged PR's rebase commit SHA in the PR's rebase comment
    #
    # @param [Hash] pull_request The PR to find the rebase commit sha for.
    # @return [String] The found commit sha
    def find_rebase_comment_sha_for_pull_request(pull_request)
      @fetcher.fetch_comments_async([pull_request])
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
