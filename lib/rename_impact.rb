# encoding: utf-8

require_relative "process_metrics"

class RenameImpactOnMetrics < Diggit::Analysis
	include ProcessMetrics

	COMMIT_WINDOW_SIZE = 400

	def run
		@file_filter = /.*/
		@file_filter_neg = /.*((\.[^\.\/\s]*\d+[^\.\/\s]*)|(LICENCE)|(README)|(\.txt)|(\.md)|(\.adoc)|(\.rtf)|(\.patch)|(\..*ignore))$/
		@modules_regexp = []
		periods = []

		walker = Rugged::Walker.new(@repo)
		walker.sorting(Rugged::SORT_TOPO)
		walker.push(@repo.last_commit)

		commits = []
		walker.each do |commit|
			next if commit.parents.size != 1
			commits << commit.oid.to_s
		end
		return if commits.size < COMMIT_WINDOW_SIZE

		idx = rand(commits.size - COMMIT_WINDOW_SIZE)
		new_release = commits[idx]
		@release_files = get_files(new_release)
		@follow_renames = true
		metrics_rename = extract_metrics(new_release,nil, false, COMMIT_WINDOW_SIZE)
		number_of_renames = 0
		@renames.each_key do |path|
			if !get_module(path).nil?
				number_of_renames = number_of_renames + 1
			end
		end
		@follow_renames = false
		metrics_no_rename = extract_metrics(new_release, nil, false, COMMIT_WINDOW_SIZE)
		@addons[:db].db['delta_metrics_400'].insert({source: @source, number_of_renames:number_of_renames, commit_oid:new_release,
												 metrics_rename: metrics_rename[:process_metrics], metrics_no_rename: metrics_no_rename[:process_metrics]})
	end

	def clean
		@addons[:db].db['delta_metrics_400'].remove({source:@source})
	end

end

class RenameImpactJoin < Diggit::Join

	def run
		@addons[:R].eval "source('#{File.expand_path("../rename_join.r", __FILE__)}')"
	end
end