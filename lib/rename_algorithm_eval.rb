# encoding: utf-8

require_relative "process_metrics"

class RenameAlgorithmEval < Diggit::Analysis

	def run
		num_false_positive = 0
		num_true_positive = 0

		walker = Rugged::Walker.new(@repo)
		walker.sorting(Rugged::SORT_TOPO)
		walker.push("HEAD")

		num_commits = 0
		walker.each do |commit|
			next if commit.parents.size != 1 # ignore merges
			num_commits = num_commits + 1
			break if num_commits == 200
			diff = commit.parents[0].diff(commit, {:context_lines => 10, :ignore_whitespace => true})
			diff.find_similar!({:renames => true, :ignore_whitespace => true})
			diff.each do |patch|
				if patch.delta.status == :renamed && !patch.delta.binary? &&
				(patch.delta.new_file[:path] =~ /.*\.((txt)|(md)|(adoc)|(rtf)|(patch))$/).nil? &&
				patch.delta.similarity != 100 && rand(10) == 0
					system "clear"
					puts patch.to_s
					puts commit.message
					puts "y/n"
					STDOUT.flush
					resp = STDIN.gets.chomp
					if resp == "n"
						num_false_positive = num_false_positive + 1
					else
						num_true_positive = num_true_positive + 1
					end
				end
			end
		end
		@addons[:db].db['rename_eval'].insert({source:@source, num_true_positive:num_true_positive, num_false_positive:num_false_positive})
	end

	def clean
		@addons[:db].db['rename_eval'].remove({source:@source})
	end
end

class RenameStatistics < Diggit::Analysis
	include ProcessMetrics

	def run
		#@renames = {}
		#rename_counts = Hash.new(0)
		walker = Rugged::Walker.new(@repo)
		walker.sorting(Rugged::SORT_TOPO | Rugged::SORT_REVERSE)
		walker.push("HEAD")

		num_commits = 0
		num_commits_w_rename = 0


		walker.each do |commit|
			next if commit.parents.size != 1 # ignore merges
			num_commits = num_commits + 1

			similarities = []
			num_renames = 0
			num_changes = 0
			languages_changes_stats = Hash.new(0)
			languages_renames_stats = Hash.new(0)

			commit.parents.each do |parent|
				diff = parent.diff(commit, {:context_lines => 10, :ignore_whitespace => true})
				diff.find_similar!({:renames => true, :ignore_whitespace => true})

				diff.each do |patch|
					patch.delta.status == :deleted ? path = patch.delta.old_file[:path] : path = patch.delta.new_file[:path]
					path.downcase!
					if (path =~ /.*((\.[^\.\/\s]*\d+[^\.\/\s]*)|(LICENCE)|(README)|(\.txt)|(\.md)|(\.adoc)|(\.rtf)|(\.patch)|(\..*ignore))$/).nil? && !patch.delta.binary?
						num_changes = num_changes + 1
						match = /^.+(\.([^\.\/\s]+))$/.match(path)
						match.nil? ? extension = "none" : extension = match[2]
						languages_changes_stats[extension] = languages_changes_stats[extension] + 1
						if patch.delta.status == :renamed
							similarities << patch.delta.similarity
							num_renames = num_renames + 1
							languages_renames_stats[extension] = languages_renames_stats[extension] + 1

							# renamed_path = patch.delta.old_file[:path]
							# @renames[renamed_path] = path unless rename_set(path).include? renamed_path
							# real_path = apply_renames(path)
							# rename_counts[real_path] = rename_counts[real_path] + 1
						end
					end

				end
				num_commits_w_rename = num_commits_w_rename + 1 if num_renames > 0

				@addons[:db].db['rename_stats_commit'].insert({source:@source, commit_oid: commit.oid.to_str,
					similarities:similarities, num_renames:num_renames, num_changes: num_changes,
					languages_changes_stats: languages_changes_stats, languages_renames_stats:languages_renames_stats, commit_pos:num_commits})
			end
		end

		# rename_counts.each_pair do |path, rename_count|
		# 	@addons[:db].db['rename_stats_file'].insert({source:@source, rename_count:rename_count, path:path})
		# end

		@addons[:db].db['rename_stats_project'].insert({source:@source, num_commits:num_commits, num_commits_w_rename:num_commits_w_rename})
	end

	def clean
		@addons[:db].db['rename_stats_project'].remove({source:@source})
		@addons[:db].db['rename_stats_commit'].remove({source:@source})
	end
end