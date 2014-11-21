# encoding: utf-8
require "rinruby"
require_relative "process_metrics"

class RenameImpactOnMetrics < Diggit::Analysis
	include ProcessMetrics

	COMMIT_WINDOW_SIZE = 200

	def run
		@file_filter = /^((?!\.txt)(?!\.rtf)(?!\.md)(?!\.adoc)(?!\.patch).)*$/
		@modules_regexp = []
		periods = []

		walker = Rugged::Walker.new(@repo)
		walker.sorting(Rugged::SORT_TOPO)
		walker.push(@repo.head.target)

		num_commits = 0
		period = {:new_release => @repo.head.target.oid.to_s}
		walker.each do |commit|
			break if commit.parents.size == 0
			num_commits = num_commits + 1 if commit.parents.size == 1 # ignore merges
			if num_commits == COMMIT_WINDOW_SIZE
				period[:old_release] = commit.oid.to_s
				periods << period
				period = {:new_release => commit.oid.to_s}
				num_commits = 0
			end
		end
		return if periods.empty?

		period = periods[rand(periods.size)] # look at one random period
		@release_files = get_files(period[:new_release])
		@follow_renames = true
		metrics_rename = extract_metrics(period[:new_release], period[:old_release], false, COMMIT_WINDOW_SIZE)
		number_of_renames = @renames.size
		@follow_renames = false
		metrics_no_rename = extract_metrics(period[:new_release], period[:old_release], false, COMMIT_WINDOW_SIZE)
		@addons[:db].db['delta_metrics'].insert({source: @source, number_of_renames:number_of_renames, period:period, metrics_rename: metrics_rename[:process_metrics], metrics_no_rename: metrics_no_rename[:process_metrics]})
	end

	def clean
		@addons[:db].db['delta_metrics'].remove({source:@source})
	end

end

class RenameImpactJoin < Diggit::Join

	def run
		R.eval "source('#{File.expand_path("../rename_join.r", __FILE__)}')"
	end

end