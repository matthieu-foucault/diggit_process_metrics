# encoding: utf-8

require_relative "process_metrics"

class DevelopersTimeline < Diggit::Analysis
	include SourcesOptionsUtil, ProcessMetrics

	def run
		@renames = {}
		@authors_merge = src_opt["authors"]
		@modules_regexp = (src_opt["modules"].nil?) ? [] : src_opt["modules"].map { |m| Regexp.new m }
		@release_files = get_files_from_db
		@file_filter = Regexp.new src_opt["file-filter"]


		release_commit = src_opt["releases"][0]
		walker = Rugged::Walker.new(@repo)
		walker.sorting(Rugged::SORT_TOPO)
		walker.push(release_commit)
		walker.each do |commit|
			next if commit.parents.size != 1
			diff = commit.parents[0].diff(commit, DIFF_OPTIONS)
			diff.find_similar!(DIFF_RENAME_OPTIONS)
			diff.each do |patch|
				file = patch.delta.new_file[:path]
				renamed_path = patch.delta.old_file[:path]
				@renames[renamed_path] = file if (patch.delta.status == :renamed) && !(rename_sources(file).include? renamed_path)
				maudule = get_module(file)
				next if maudule.nil?

				author = commit.author[:name]
				author = @authors_merge[author] if (defined? @authors_merge) && (@authors_merge.has_key? author)


				@addons[:db].db["developers_timeline"].insert({source:@source, author:author, 'module' => maudule, time:commit.author[:time]})
			end


			
		end
	end

	def clean
		@addons[:db].db["developers_timeline"].remove({source:@source})
	end
	
end
