# encoding: utf-8
require 'pry'

class ProcessMetricsAnalysis < Diggit::Analysis
	include SourcesOptionsUtil

	def get_module(path)
		while @renames.has_key? path
			path = @renames[path]
		end
		return nil unless (@release_files.include? path) && (@file_filter =~ path)
		@modules_regexp.each do |module_regexp|
			return module_regexp.to_s if module_regexp =~ path
		end

		path
	end

	def extract_metrics(new_release, old_release, extract_code_metrics = false)
		contributions = Hash.new { |hash, key| hash[key] = {:touches => 0, :churn => 0} }
		modules_churn = Hash.new(0)
		modules_touches = Hash.new(0)
		modules_authors = Hash.new { |hash, key| hash[key] = Set.new }

		walker = Rugged::Walker.new(@repo)
		walker.sorting(Rugged::SORT_TOPO)
		walker.push(new_release)
		walker.hide(old_release)

		walker.each do |commit|
			next if commit.parents.size != 1 # ignore merges

			author = commit.author[:name]
			author = @authors_merge[author] if @authors_merge.has_key? author

			diff = commit.parents[0].diff(commit)
			diff.find_similar!
			diff.each do |patch|
				file = patch.delta.new_file[:path]
				maudule = get_module(file)
				next if maudule.nil?

				@renames[patch.delta.old_file[:path]] = file if patch.delta.status == :renamed

				modules_churn[maudule] = modules_churn[maudule] + patch.stat[0] + patch.stat[1]
				modules_touches[maudule] = modules_touches[maudule] + 1
				modules_authors[maudule] = (modules_authors[maudule] << author)
				key = {:author => author, :module => maudule}
				contributions[key] = {:touches => contributions[key][:touches] + 1, :churn => contributions[key][:churn] + patch.stat[0] + patch.stat[1]}
			end
		end
		release_date = @repo.lookup(new_release).author[:time]
		# compute metrics and write to mongo
		contributions.each do |key,value|
			@addons[:db].db["contributions"].insert({project: @source, developer: key[:author], "module" => key[:module],
													ownModule: value[:touches].to_f/modules_touches[key[:module]],
													ownModuleChurn: value[:churn].to_f/modules_churn[key[:module]],
													touches: value[:touches], churn: value[:churn], releaseDate: release_date})

		end

		return unless extract_code_metrics

		@modules_loc.each do |maudule, loc|
			@addons[:db].db["module-metrics"].insert({project: @source, "module" => maudule, "LoC" => loc,
													 "BugFixes" => @modules_bugfixes[maudule].size, churn: modules_churn[maudule], touches: modules_touches[maudule]})
		end

	end

	def extract_bugfixes
		@modules_bugfixes = Hash.new { |hash, key| hash[key] = Set.new }
		src_opt["bug-fix-commits"].each do |commit_oid|
			commit = @repo.lookup(commit_oid)
			next if commit.parents.size != 1 # ignore merges
			diff = commit.parents[0].diff(commit)
			diff.find_similar!
			diff.each do |patch|
				file = patch.delta.old_file[:path]
				file = patch.delta.new_file[:path] if patch.delta.status == :created
				maudule = get_module(file)
				@modules_bugfixes[maudule] = (@modules_bugfixes[maudule] << commit_oid) unless maudule.nil?
			end
		end
	end

	def extract_loc
		@modules_loc = Hash.new(0)
		cloc_source = @addons[:db].db['cloc-file'].find_one({source: @source})
		cloc_source["cloc"].each do |cloc_file|
			maudule = get_module(cloc_file["path"])
			@modules_loc[maudule] = @modules_loc[maudule] + cloc_file["code"] unless maudule.nil?
		end

	end

	def run
		@releases = src_opt["releases"]
		@authors_merge = src_opt["authors"]
		@file_filter = Regexp.new src_opt["file-filter"]
		@modules_regexp = []
		@modules_regexp = src_opt["modules"].map { |m| Regexp.new m } unless src_opt["modules"].nil?
		@renames = {}


		@release_files = Set.new
		@repo.lookup(@releases[0]).tree.walk_blobs do |root, entry|
			unless @repo.lookup(entry[:oid]).binary?
				@release_files << "#{root}#{entry[:name]}"
			end
		end

		extract_loc
		extract_bugfixes
		extract_metrics(@releases[0], @releases[1], true)

	end

	def clean
		@addons[:db].db["contributions"].remove({project:@source})
		@addons[:db].db["module-metrics"].remove({project:@source})
	end

end