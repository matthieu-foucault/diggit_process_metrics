# encoding: utf-8

require_relative "process_metrics"

class AuthorshipAnalysis < Diggit::Analysis
	include SourcesOptionsUtil, ProcessMetrics

	REGEX_AUTHOR_SCORE = /^[a-f0-9]+\s+(.*)\s+\d+\/\d+=(\d+\.?\d*)%\s*$/

	## @return the number of lines per author (may not be an integer)
	def parse_file_authorship(file)
		file_authorship = Hash.new(0)
		command_res = `#{@git_author_command} -W #{file}`
		command_res.split("\n").each do |line|
			m_data = REGEX_AUTHOR_SCORE.match(line)
			unless m_data.nil?
				author = m_data[1].strip
				author = @authors_merge[author] if (defined? @authors_merge) && (@authors_merge.has_key? author)
				score = m_data[2].to_f / 100
				file_authorship[author] = file_authorship[author] + score
			end
		end
		file_authorship
	end

	def record_modules_authorships(commit_oid)
		@repo.checkout(commit_oid, {:strategy=>[:force,:remove_untracked]})
		modules_authorships = Hash.new { |hash, key| hash[key] = Hash.new(0) }

		Dir['./**/*'].each do |file|
			file.gsub!(/^\.\//,'')
			modul = get_module(file)
			unless modul.nil?
				parse_file_authorship(file).each_pair { |author, score|	modules_authorships[modul][author] = modules_authorships[modul][author] + score } 
			end
		end
		commit_date = @repo.lookup(commit_oid).committer[:time]
		modules_authorships.each_pair do |modul, module_authorship|
			module_authorship.each_pair do |author, score|
				@addons[:db].db["authorship"].insert({ source:@source, commit_date:commit_date, 'module' => modul, author:author, score:score })
			end
			
		end
	end

	def initialize(*args)
		super(*args)
		load_options
	end

	def load_options
		@releases = src_opt["releases"]
		@release_files = get_files_from_db

		@periods = []
		if @all_releases
			@periods = [[@releases[0], @releases[1]],[@releases[1], @releases[2]]] if @releases.size == 3
		else
			@periods = [[@releases[0], @releases[1]]]
		end

		@authors_merge = src_opt["authors"]
		@file_filter = Regexp.new src_opt["file-filter"]
		@modules_regexp = []
		@modules_regexp = src_opt["modules"].map { |m| Regexp.new m } unless src_opt["modules"].nil? || ((@options.has_key? "ignore_modules") && @options["ignore_modules"])

		@renames = {}
		@git_author_command = @options["git_author_command"]
	end

	def run
		commits = get_commits_between(@releases[0], @releases[1])
		walker = Rugged::Walker.new(@repo)
		walker.sorting(Rugged::SORT_TOPO)
		walker.simplify_first_parent
		walker.push(@releases[0])

		num_recorded_snapshots = 1
		release_commit = @repo.lookup(@releases[0])
		record_modules_authorships(@releases[0])
	    #last_snapshot_time = release_commit.committer[:time]

	    num_commits_since_last_snapshot = 0
	    walker.each do |commit|
	    	extract_commit_renames(commit)
	    	num_commits_since_last_snapshot = num_commits_since_last_snapshot + 1
	    	if num_commits_since_last_snapshot == 100
	    		num_commits_since_last_snapshot = 0
	    		record_modules_authorships(commit.oid.to_s)
	    		num_recorded_snapshots = num_recorded_snapshots + 1
	    		return if num_recorded_snapshots == 10
	    	end
	    end

	end

	def clean
		@addons[:db].db["authorship"].remove({ source:@source })
	end
end