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

class RenameSatistics < Diggit::Analysis

	def run
		walker = Rugged::Walker.new(@repo)
		walker.sorting(Rugged::SORT_TOPO)
		walker.push("HEAD")

		num_commits = 0

		num_renames_per_commit = Hash.new(0)
		similarities = []

		walker.each do |commit|
			next if commit.parents.size != 1 # ignore merges
			num_commits = num_commits + 1
			break if num_commits == 200
			diff = commit.parents[0].diff(commit, {:context_lines => 10, :ignore_whitespace => true})
			diff.find_similar!({:renames => true, :ignore_whitespace => true})
			diff.each do |patch|
				if patch.delta.status == :renamed && !patch.delta.binary? &&
				(patch.delta.new_file[:path] =~ /.*\.((txt)|(md)|(adoc)|(rtf)|(patch))$/).nil?
					similarities << patch.delta.similarity
					num_renames_per_commit[commit.oid.to_s] = num_renames_per_commit[commit.oid.to_s] + 1
				end
			end
		end
		@addons[:db].db['rename_stats'].insert({source:@source, similarities:similarities, num_renames_per_commit:num_renames_per_commit.values})
	end

	def clean
		@addons[:db].db['rename_stats'].remove({source:@source})
	end
end