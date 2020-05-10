require "semantic_version"

module Bindgen
  class FindPath
    # Checker for a `VersionCheck`.  This is a special checker.  It can't be
    # instantiated in the `PathConfig#checks` array, but only through
    # `PathConfig#version`.
    class VersionChecker < Checker
      alias Candidates = Array({String, String})

      LOWEST_POSSIBLE  = " "
      HIGHEST_POSSIBLE = "~"

      # Stores all candidates
      getter candidates = Candidates.new

      def initialize(@config : VersionCheck)
      end

      # Returns the list of sorted candidates, from the best candidate first
      # down to worse candidates.
      def sorted_candidates : Array({String, String})
        list = @candidates.sort_by!(&.first)

        if @config.prefer.lowest?
          list
        else
          list.reverse
        end
      end

      # Returns the best checked candidate
      def best_candidate : String?
        @candidates.sort_by!(&.first)

        tuple = if @config.prefer.lowest?
                  @candidates.first?
                else
                  @candidates.last?
                end

        tuple.last if tuple # Unpack the path if we found anything.
      end

      # Checks *path* by calling out to the configured shell command, expanding
      # *path* into it.  `STDOUT` is hidden, but `STDERR` is shown.  Only
      # succeeds if the command returned exit code `0`.
      def check(path : String) : Bool
        regex = Regex.new(@config.regex, FindPath::MULTILINE_OPTION)
        version_string = get_version_number(path, regex, @config.command)

        if version_string # Version string check
          return false unless check_version_string(version_string)
        else # No version string found, use fallback configuration
          version_string = fallback_version
          return false if version_string.nil?
        end

        # Accept!
        @candidates << {version_string, path}
        true
      end

      private def fallback_version : String?
        case @config.fallback
        when .fail?
          nil # Bail
        when .accept?
          if @config.prefer.highest?
            LOWEST_POSSIBLE
          else
            HIGHEST_POSSIBLE
          end
        when .prefer?
          if @config.prefer.highest?
            HIGHEST_POSSIBLE
          else
            LOWEST_POSSIBLE
          end
        else
          raise "BUG: Unreachable!"
        end
      end

      # Does the version check
      private def check_version_string(version_string) : Bool
        version = ensure_semantic_version version_string
        min = ensure_semantic_version @config.min
        max = ensure_semantic_version @config.max

        if min
          return false if version < min
        end

        if max
          return false if version > max
        end

        true
      end

      # Matches *regex* on the *path* to figure out the version
      private def get_version_number(path, regex, command : Nil) : String?
        capture_match(regex, path)
      end

      # Calls *command* and applies *regex* on it to figure out the version.
      private def get_version_number(path, regex, command : String) : String?
        command = Util.template(command, replacement: path)
        output = `#{command}`

        return nil unless $?.success?
        capture_match(regex, output)
      end

      # Matches *regex* on *string*, and returns the first capture group if any.
      private def capture_match(regex, string)
        if match = regex.match(string)
          match[1]?
        end
      end

      # Ensures that *version* has 3 components needed for semantic version comparison
      # and returns SemanticVersion object.
      #
      # ```
      # pp ensure_semantic_version("10")     # => SemanticVersion.new("10.0.0")
      # pp ensure_semantic_version("10.2")   # => SemanticVersion.new("10.2.0")
      # pp ensure_semantic_version("10.3.0") # => SemanticVersion.new("10.3.0")
      # ```
      private def ensure_semantic_version(version)
        version.try { |v|
          if (dots = v.count('.')) < 2
            (2 - dots).times { v += ".0" }
          end
          SemanticVersion.parse v
        }
      end
    end
  end
end
