# encoding: utf-8
unless defined? ProcessMetrics

module ProcessMetrics

	DIFF_OPTIONS = {:ignore_whitespace => true,:ignore_filemode => true}
	DIFF_RENAME_OPTIONS = {:renames => true, :ignore_whitespace => true}

	# The set of names that should be renamed to the given path
	def rename_sources(path)
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
		if (defined? @renames) && !((defined? @follow_renames) && !@follow_renames)
			path = apply_renames(path)
		end
		return nil unless (@release_files.include? path) && (@file_filter =~ path) && (!(defined? @file_filter_neg) || (@file_filter_neg =~ path).nil?)
		@modules_regexp.each do |module_regexp|
			return module_regexp.to_s if module_regexp =~ path
		end

		path
	end

	def get_author(commit)
		author = commit.author[:name].downcase
		((defined? @authors_merge) && (@authors_merge.has_key? author)) ? @authors_merge[author] : author
	end

	def get_patch_module(patch)
		file = patch.delta.old_file[:path]
		file = patch.delta.new_file[:path] if patch.delta.status == :created
		get_module(file)
	end

	def get_periods_commits(r_0, r_m1, r_m2)
		p_0m1 = []
		p_m1m2 = []

		walker = Rugged::Walker.new(@repo)
		walker.sorting(Rugged::SORT_DATE)
		walker.push(@repo.lookup(r_0))

		t_m1 = @repo.lookup(r_m1).author[:time]
		t_m2 = @repo.lookup(r_m2).author[:time]

		walker.each do |commit|
			t = commit.author[:time] 
			if t > t_m1
				p_0m1 << commit
			elsif t > t_m2
				p_m1m2 << commit
			elsif t < t_m2
			 	break
			end
			
		end
		[p_0m1, p_m1m2]
	end

	# The list of commits that are between the given commits, taking into account the topological view of the history
	def get_commits_between(new_commit_str, old_commit_str, reverse = false)
		if (new_commit_str == old_commit_str) 
			return [@repo.lookup(new_commit_str)]
		end
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
		until commits_to_visit.empty?
			commit = commits_to_visit.pop
			if (discovered_commits.add?(commit)) && commit != new_commit
				result << @repo.lookup(commit)
				commits_children[commit].each { |child|	commits_to_visit << child }
			end
		end
		result << new_commit
		if reverse
			result
		else
			result.reverse
		end
	end

	def get_walker(new_release, old_release, reverse = false)
		if old_release.nil?
			walker = Rugged::Walker.new(@repo)
			walker.sorting(Rugged::SORT_TOPO)
			walker.push(new_release)
		else
			walker = get_commits_between(new_release, old_release, reverse)
		end
		walker
	end

	def extract_commit_renames(commit, reverse = false) 
		commit.parents.each do |parent|
			diff = parent.diff(commit, DIFF_OPTIONS)
			diff.find_similar!(DIFF_RENAME_OPTIONS) unless (defined? @follow_renames) && !@follow_renames
			diff.each do |patch|
				if reverse
					renamed_path = patch.delta.new_file[:path]
					file = patch.delta.old_file[:path]
				else
					file = patch.delta.new_file[:path]
					renamed_path = patch.delta.old_file[:path]
				end
				@renames[renamed_path] = file if (patch.delta.status == :renamed) && !(rename_sources(file).include? renamed_path)
			end
		end 
	end

	def extract_renames(walker, reverse = false)
		walker.each { |commit| extract_commit_renames(commit, reverse) }
	end

	# Extracts process and (optionally) code metrics between the two given releases
	#
	# @param new_release [String] a string with the OID of the commit in the repository
	# @param old_release [String] a string with the OID of the commit in the repository
	# @return [Hash] a hash with the metrics. The two possible keys are :process_metrics and :module_metrics
	def extract_developer_metrics(new_release, old_release = nil, reverse = false,
		commits = nil, release_0 = nil, custom_id = nil)

		@renames = {} unless defined? @renames
		contributions = Hash.new { |hash, key| hash[key] = {:touches => 0, :churn => 0} }
		num_commits = 0

		unless commits.nil?
			walker = commits
		else
			walker = get_walker(new_release, old_release, reverse)
			extract_renames(walker, reverse)
			walker = get_walker(new_release, old_release, reverse) #walker must be reset	
		end
		
		walker.each do |commit|
			next if @ignore_merges && commit.parents.size != 1
			num_commits = num_commits + 1

			author = get_author(commit)

			commit.parents.each do |parent|
				diff = parent.diff(commit, DIFF_OPTIONS)
				diff.find_similar!(DIFF_RENAME_OPTIONS)
				diff.each do |patch|
					maudule = get_patch_module(patch)
					next if maudule.nil?

					key = {:author => author, :module => maudule}
					contributions[key] = {:touches => contributions[key][:touches] + 1, :churn => contributions[key][:churn] + patch.stat[0] + patch.stat[1]}
				end
			end
		end

		puts "num commits #{num_commits}"

		release_date = @repo.lookup(new_release).author[:time]
		release_0_date = release_0.nil? ? nil : @repo.lookup(release_0).author[:time]

		# compute metrics and write to result
		developer_metrics = []
		contributions.each do |key,value|

			developer_metrics << {project: @source, developer: key[:author], "module" => key[:module],
				touches: value[:touches], churn: value[:churn], releaseDate: release_date, 
				releaseId:new_release, release0:release_0, release0Date:release_0_date, custom_id:custom_id}
		end
		developer_metrics
	end

	def extract_module_metrics
		modules_bugfixes = extract_bugfixes
		modules_loc = extract_loc

		modules_metrics = []
		modules_loc.each do |maudule, loc|
			modules_metrics << {project: @source, "module" => maudule, "LoC" => loc,
				"BugFixes" => modules_bugfixes[maudule].size}
		end
		modules_metrics
	end

	def extract_bugfixes
		modules_bugfixes = Hash.new { |hash, key| hash[key] = Set.new }
		src_opt["bug-fix-commits"].each do |commit_oid|
			commit = @repo.lookup(commit_oid)
			next if commit.parents.size != 1 # ignore merges
			diff = commit.parents[0].diff(commit, DIFF_OPTIONS)
			diff.find_similar!(DIFF_RENAME_OPTIONS)
			diff.each do |patch|
				maudule = get_patch_module(patch)
				modules_bugfixes[maudule] = (modules_bugfixes[maudule] << commit_oid) unless maudule.nil?
			end
		end
		modules_bugfixes
	end

	def extract_loc
		modules_loc = Hash.new(0)
		cloc_source = @addons[:db].db['cloc-file'].find_one({source: @source})
		cloc_source["cloc"].each do |cloc_file|
			maudule = get_module(cloc_file["path"])
			modules_loc[maudule] = modules_loc[maudule] + cloc_file["code"] unless maudule.nil?
		end
		modules_loc
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

	PROCESS_METRICS_COL = "developer_metrics"

	def initialize(*args)
		super(*args)
		load_options
	end

	def load_options
		@follow_renames = (@options.has_key? "follow_renames") ? @options["follow_renames"] : true
		@ignore_merges = (@options.has_key? "ignore_merges") ? @options["ignore_merges"] : true
		@releases = src_opt["releases"]
		@all_releases = false
		@all_releases = @options["all_releases"] if @options.has_key? "all_releases"

		@authors_merge = {}
		src_opt["authors"].each_pair do |k, v|
			@authors_merge[k.downcase] = v.downcase
		end
		
		@file_filter = Regexp.new src_opt["file-filter"]
		@modules_regexp = []
		@modules_regexp = src_opt["modules"].map { |m| Regexp.new m } unless src_opt["modules"].nil? || ((@options.has_key? "ignore_modules") && @options["ignore_modules"])
		@modules_metrics = true
		@modules_metrics = @options["modules_metrics"] if @options.has_key? "modules_metrics"

	end

	def run
		@release_files = get_files_from_db

		release_0 = src_opt["cloc-commit-id"]
		releases = src_opt["releases"]

		@renames = {}
		
		releases.each_with_index do |r, i|
			if i < (releases.length - 2)
				puts "release #{r}"
				periods_commits = get_periods_commits(r, releases[i + 1], releases[i + 2])
				periods_commits.each { |p| extract_renames(p) }
				puts "p1"
				m = extract_developer_metrics(r, releases[i + 1], false, periods_commits[0], r)
				@addons[:db].db[PROCESS_METRICS_COL].insert(m) unless m.empty?
				puts "p2"
				m = extract_developer_metrics(releases[i + 1], releases[i + 2],false, periods_commits[1], r)
				@addons[:db].db[PROCESS_METRICS_COL].insert(m) unless m.empty?
			end
		end
	end

	def clean
		@addons[:db].db[PROCESS_METRICS_COL].remove({project:@source})
	end
end

class ModulesMetrics < ProcessMetricsAnalysis
	MODULES_METRICS_COL = "modules_metrics"

	def run
		@release_files = get_files_from_db


		metrics = extract_module_metrics
		@addons[:db].db[MODULES_METRICS_COL].insert(metrics)
	end

	def clean
		@addons[:db].db[MODULES_METRICS_COL].remove({project:@source})
	end
end

end
