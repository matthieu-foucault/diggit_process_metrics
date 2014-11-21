# encoding: utf-8
require 'pry'

module ProcessMetrics

	def rename_set(path)
		set = Set.new
		set << path
		while @renames.has_key? path
			path = @renames[path]
			set << path
		end
		set
	end

	def get_module(path)
		if (defined? @renames) && !((defined? @follow_renames) && (@follow_renames == false))
			while @renames.has_key? path
				path = @renames[path]
			end
		end
		return nil unless (@release_files.include? path) && (@file_filter =~ path)
		@modules_regexp.each do |module_regexp|
			return module_regexp.to_s if module_regexp =~ path
		end

		path
	end

	def get_commits_between(new_commit_str, old_commit_str)
		new_commit = @repo.lookup(new_commit_str)
		old_commit = @repo.lookup(old_commit_str)

		walker = Rugged::Walker.new(@repo)
		walker.sorting(Rugged::SORT_TOPO)
		walker.push(new_commit)
		old_commit.parents.each { |p| walker.hide(p) }

		commits_children = Hash.new { |hash, key| hash[key] = Set.new }
		walker.each do |commit|
			commit.parents.each do |parent|
				commits_children[parent] << commit
			end
		end
		commits_to_visit = [old_commit]
		discovered_commits = Set.new
		result = []
		while !commits_to_visit.empty?
			commit = commits_to_visit.pop
			if (discovered_commits.add?(commit)) && commit != new_commit
				result << commit
				commits_children[commit].each { |child|	commits_to_visit << child }
			end
		end
		result << new_commit
		result.reverse
	end


	# Extracts process and (optionally) code metrics between the two given releases
	#
	# @param new_release [String] a string with the OID of the commit in the repository
	# @param old_release [String] a string with the OID of the commit in the repository
	# @return [Hash] a hash with the metrics. The two possible keys are :process_metrics and :module_metrics
	def extract_metrics(new_release, old_release = nil, extract_code_metrics = false, max_commits = -1)
		@renames = {}
		contributions = Hash.new { |hash, key| hash[key] = {:touches => 0, :churn => 0} }
		modules_churn = Hash.new(0)
		modules_touches = Hash.new(0)
		modules_authors = Hash.new { |hash, key| hash[key] = Set.new }

		if old_release.nil?
			walker = Rugged::Walker.new(@repo)
			walker.sorting(Rugged::SORT_TOPO)
			walker.push(new_release)
		else
			walker = get_commits_between(new_release, old_release)
		end

		num_commit = 1
		walker.each do |commit|
			break if max_commits != 1 && num_commit == max_commits
			next if commit.parents.size != 1 # ignore merges
			print "#{@source}: extracting commit #{num_commit}: #{commit.oid.to_s}\r"
			num_commit = num_commit + 1

			author = commit.author[:name]
			author = @authors_merge[author] if (defined? @authors_merge) && (@authors_merge.has_key? author)

			diff = commit.parents[0].diff(commit)
			diff.find_similar!({:renames => true, :ignore_whitespace => true}) unless (defined? @follow_renames) && (@follow_renames == false)
			diff.each do |patch|
				file = patch.delta.new_file[:path]
				maudule = get_module(file)
				next if maudule.nil?
				renamed_path = patch.delta.old_file[:path]
				@renames[renamed_path] = file if (patch.delta.status == :renamed) && !(rename_set(file).include? renamed_path)

				modules_churn[maudule] = modules_churn[maudule] + patch.stat[0] + patch.stat[1]
				modules_touches[maudule] = modules_touches[maudule] + 1
				modules_authors[maudule] = (modules_authors[maudule] << author)
				key = {:author => author, :module => maudule}
				contributions[key] = {:touches => contributions[key][:touches] + 1, :churn => contributions[key][:churn] + patch.stat[0] + patch.stat[1]}
			end
		end
		release_date = @repo.lookup(new_release).author[:time]
		# compute metrics and write to result
		process_metrics = []
		contributions.each do |key,value|
			ownModuleChurn = 0
			ownModuleChurn = value[:churn].to_f/modules_churn[key[:module]] if modules_churn[key[:module]] != 0

			process_metrics << {project: @source, developer: key[:author], "module" => key[:module],
								ownModule: value[:touches].to_f/modules_touches[key[:module]],
								ownModuleChurn: ownModuleChurn,
								touches: value[:touches], churn: value[:churn], releaseDate: release_date}
		end
		result = {:process_metrics => process_metrics}

		return result unless extract_code_metrics

		modules_metrics = []
		@modules_loc.each do |maudule, loc|
			modules_metrics << {project: @source, "module" => maudule, "LoC" => loc,
								"BugFixes" => @modules_bugfixes[maudule].size,
								churn: modules_churn[maudule],
								touches: modules_touches[maudule]}
		end
		result[:module_metrics] = modules_metrics
		result
	end

	def extract_bugfixes
		@modules_bugfixes = Hash.new { |hash, key| hash[key] = Set.new }
		src_opt["bug-fix-commits"].each do |commit_oid|
			commit = @repo.lookup(commit_oid)
			next if commit.parents.size != 1 # ignore merges
			diff = commit.parents[0].diff(commit)
			diff.find_similar! unless (defined? @follow_renames) && (@follow_renames == false)
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

	def get_files(commit_oid)
		release_files = Set.new
		@repo.lookup(commit_oid).tree.walk_blobs do |root, entry|
			unless @repo.lookup(entry[:oid]).binary?
				release_files << "#{root}#{entry[:name]}"
			end
		end
		release_files
	end

end

class ProcessMetricsAnalysis < Diggit::Analysis
	include SourcesOptionsUtil, ProcessMetrics

	def run
		@follow_renames = true
		@follow_renames = @options["follow_renames"] if @options.has_key? "follow_renames"
		@releases = src_opt["releases"]
		@authors_merge = src_opt["authors"]
		@file_filter = Regexp.new src_opt["file-filter"]
		@modules_regexp = []
		@modules_regexp = src_opt["modules"].map { |m| Regexp.new m } unless src_opt["modules"].nil? || ((@options.has_key? "ignore_modules") && (@options["ignore_modules"] == true))


		@release_files = get_files(@releases[0])

		extract_loc
		extract_bugfixes
		metrics = extract_metrics(@releases[0], @releases[1], true)
		binding.pry
		@addons[:db].db["process_metrics"].insert(metrics[:process_metrics])
		@addons[:db].db["modules_metrics"].insert(metrics[:module_metrics])

	end

	def clean
		@addons[:db].db["process_metrics"].remove({project:@source})
		@addons[:db].db["modules_metrics"].remove({project:@source})
	end
end

class ProcessMetricsJoin < Diggit::Join

end