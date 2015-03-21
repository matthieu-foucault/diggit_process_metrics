# encoding: utf-8

require_relative "process_metrics"

TIME_PERIOD_SIZE = 3600 * 24 * 30

class TurnoverPeriodsAfter < ProcessMetricsAnalysis
	PERIODS_AFTER_COL = "developer_metrics_periods_after"
	def run
		@release_files = get_files_from_db
		r_0 = @repo.lookup(src_opt["cloc-commit-id"])
		r_last = @repo.lookup(src_opt["R_last"])
		t_0 = r_0.author[:time]


		walker = Rugged::Walker.new(@repo)
		walker.sorting(Rugged::SORT_DATE | Rugged::SORT_REVERSE)
		walker.push(r_last)

		@renames = {}
		t_next_month = t_0 + TIME_PERIOD_SIZE
		month_num = 1
		commits = []
		walker.each do |commit|
			t = commit.author[:time]
			next if t < t_0
			extract_commit_renames(commit, true)
			commits << commit if commit.parents.size == 1
			if t > t_next_month
				puts "Month #{month_num}, #{commits.size} commits"
				m = extract_developer_metrics(commits[0].oid.to_s, nil, true,
					commits, commits[0].oid.to_s, month_num)
				@addons[:db].db[PERIODS_AFTER_COL].insert(m) unless m.empty?
				month_num = month_num + 1
				t_next_month = t_next_month + TIME_PERIOD_SIZE
				commits = []
			end

		end
	end

	def clean
		@addons[:db].db[PERIODS_AFTER_COL].remove({project:@source})
	end
end

class TurnoverPeriodsBefore < ProcessMetricsAnalysis
	PERIODS_BEFORE_COL = "developer_metrics_periods_before"
	def run
		@release_files = get_files_from_db
		r_0 = @repo.lookup(src_opt["cloc-commit-id"])
		t_first = @repo.lookup(src_opt["R_first"]).author[:time]

		# consider all commits from r_last to r_0, and group them in 500 commits periods
		t_0 = r_0.author[:time]


		walker = Rugged::Walker.new(@repo)
		walker.sorting(Rugged::SORT_DATE)
		walker.push(r_0)

		@renames = {}
		t_previous_month = t_0 - TIME_PERIOD_SIZE
		month_num = 1
		commits = []
		walker.each do |commit|
			t = commit.author[:time]
			extract_commit_renames(commit, false)
			commits << commit if commit.parents.size == 1
			if t < t_previous_month || t < t_first
				puts "Month #{month_num}, #{commits.size} commits"
				m = extract_developer_metrics(commits[0].oid.to_s, nil, false,
					commits, commits[0].oid.to_s, month_num)
				@addons[:db].db[PERIODS_BEFORE_COL].insert(m) unless m.empty?
				month_num = month_num + 1
				t_previous_month = t_previous_month - TIME_PERIOD_SIZE
				commits = []
			end
			break if t < t_first
		end
	end

	def clean
		@addons[:db].db[PERIODS_BEFORE_COL].remove({project:@source})
	end
end

class TurnoverEvol < ProcessMetricsAnalysis
	EVOL_COL = "turnover_evol"

	def run
		r_last = @repo.lookup(src_opt["R_last"])
		r_first_time = @repo.lookup(src_opt["R_first"]).author[:time]


		walker = Rugged::Walker.new(@repo)
		walker.sorting(Rugged::SORT_DATE)
		walker.push(r_last)

		devs = []
		walker.each do |commit|
			t = commit.author[:time]
			author = get_author(commit)
			devs << {project:@source, author:author, time:t}

			if t < r_first_time
				break
			end
		end

		@addons[:db].db[EVOL_COL].insert(devs)

	end

	def clean
		@addons[:db].db[EVOL_COL].remove({project:@source})
	end
end