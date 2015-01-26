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

	def apply_renames(path)
		while @renames.has_key? path
			path = @renames[path]
		end
		path
	end

	def get_module(path)
		if (defined? @renames) && !((defined? @follow_renames) && (@follow_renames == false))
			path = apply_renames(path)
		end
		return nil unless (@release_files.include? path) && (@file_filter =~ path) && (!(defined? @file_filter_neg) || (@file_filter_neg =~ path).nil?)
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
				commits_children[parent.oid.to_s] << commit.oid.to_s
			end
		end
		commits_to_visit = [old_commit_str]
		discovered_commits = Set.new
		result = []
		while !commits_to_visit.empty?
			commit = commits_to_visit.pop
			if (discovered_commits.add?(commit)) && commit != new_commit
				result << @repo.lookup(commit)
				commits_children[commit].each { |child|	commits_to_visit << child }
			end
		end
		result << new_commit
		puts "num commits #{result.size}"
		result.reverse
	end


	# Extracts process and (optionally) code metrics between the two given releases
	#
	# @param new_release [String] a string with the OID of the commit in the repository
	# @param old_release [String] a string with the OID of the commit in the repository
	# @return [Hash] a hash with the metrics. The two possible keys are :process_metrics and :module_metrics
	def extract_metrics(new_release, old_release = nil, extract_code_metrics = false, max_commits = -1)
		@renames = {} unless defined? @renames
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
		walker.each do |commit|
			next if commit.parents.size != 1 # ignore merges
			diff = commit.parents[0].diff(commit)
			diff.find_similar!({:renames => true, :ignore_whitespace => true}) unless (defined? @follow_renames) && (@follow_renames == false)
			diff.each do |patch|
				file = patch.delta.new_file[:path]
				renamed_path = patch.delta.old_file[:path]
				@renames[renamed_path] = file if (patch.delta.status == :renamed) && !(rename_set(file).include? renamed_path)
			end
		end
		puts "num renames #{@renames.size}"
		num_commit = 1
		if old_release.nil?
			walker = Rugged::Walker.new(@repo)
			walker.sorting(Rugged::SORT_TOPO)
			walker.push(new_release)
		end
		walker.each do |commit|
			break if max_commits != -1 && num_commit == max_commits
			next if commit.parents.size != 1 # ignore merges
			num_commit = num_commit + 1

			author = commit.author[:name]
			author = @authors_merge[author] if (defined? @authors_merge) && (@authors_merge.has_key? author)

			commit.parents.each do |parent|
				diff = parent.diff(commit)
				diff.find_similar!({:renames => true, :ignore_whitespace => true}) unless (defined? @follow_renames) && (@follow_renames == false)
				diff.each do |patch|
					file = patch.delta.new_file[:path]
					maudule = get_module(file)
					next if maudule.nil?
					#renamed_path = patch.delta.old_file[:path]
					#@renames[renamed_path] = file if (patch.delta.status == :renamed) && !(rename_set(file).include? renamed_path)

					modules_churn[maudule] = modules_churn[maudule] + patch.stat[0] + patch.stat[1]
					modules_touches[maudule] = modules_touches[maudule] + 1
					modules_authors[maudule] = (modules_authors[maudule] << author)
					key = {:author => author, :module => maudule}
					contributions[key] = {:touches => contributions[key][:touches] + 1, :churn => contributions[key][:churn] + patch.stat[0] + patch.stat[1]}
				end
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

	def get_files_from_db
		release_files = Set.new
		cloc_source = @addons[:db].db['cloc-file'].find_one({source: @source})
		cloc_source["cloc"].each do |cloc_file|
			release_files << cloc_file["path"]
		end
		release_files
	end

	def get_files(commit_oid)
		@repo.checkout(commit_oid, {:strategy=>[:force,:remove_untracked]})
		Dir['./**/*'].map { |e| e.gsub(/^\.\//,'')}
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
		modules_metrics = true
		modules_metrics = @options["modules_metrics"] if @options.has_key? "modules_metrics"
		all_releases = false
		all_releases = @options["all_releases"] if @options.has_key? "all_releases"


		@release_files = get_files_from_db
		process_metrics_coll = "process_metrics_#{all_releases ? 'turnover' : 'own'}_#{'no_' if !@follow_renames}rename"
		modules_metrics_coll = "modules_metrics_#{'no_' if !@follow_renames}rename" if modules_metrics

		extract_loc if modules_metrics
		extract_bugfixes if modules_metrics

		periods = []
		if all_releases
			periods = [[@releases[0], @releases[1]],[@releases[1], @releases[2]]] if @releases.size == 3
		else
			periods = [[@releases[0], @releases[1]]]
		end

		periods.each do |period|
			metrics = extract_metrics(period[0], period[1], modules_metrics)
			@addons[:db].db[process_metrics_coll].insert(metrics[:process_metrics])
			@addons[:db].db[modules_metrics_coll].insert(metrics[:module_metrics]) if modules_metrics
		end


	end

	def clean
		modules_metrics = true
		modules_metrics = @options["modules_metrics"] if @options.has_key? "modules_metrics"
		all_releases = false
		all_releases = @options["all_releases"] if @options.has_key? "all_releases"
		follow_renames = true
		follow_renames = @options["follow_renames"] if @options.has_key? "follow_renames"

		process_metrics_coll = "process_metrics_#{all_releases ? 'turnover' : 'own'}_#{'no_' if !follow_renames}rename"
		modules_metrics_coll = "modules_metrics_#{'no_' if !follow_renames}rename" if modules_metrics
		@addons[:db].db[process_metrics_coll].remove({project:@source})
		@addons[:db].db[modules_metrics_coll].remove({project:@source}) if modules_metrics
	end
end

class ProcessMetricsJoin < Diggit::Join

end