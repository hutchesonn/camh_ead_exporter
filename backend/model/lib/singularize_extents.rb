module SingularizeExtents

	def self.singularized_extents
		{
			"linear_feet"=>"linear foot",
			"volumes"=>"volume",
			"folders"=>"folder",
			"videotapes"=>"videotape",
			"audiotapes"=>"audiotape",
			"boxes"=>"box",
			"cassettes"=>"cassette",
			"cubic feet"=>"cubic foot",
			"discs"=>"disc",
			"files"=>"file",
			"gigabytes"=>"gigabyte",
			"inches"=>"inch",
			"items"=>"item",
			"leaves"=>"leaf",
			"maps"=>"map",
			"megabytes"=>"megabyte",
			"photographic_negatives"=>"photographic negative",
			"photographic_prints"=>"photographic print",
			"photographic_slides"=>"photographic slide",
			"reels"=>"reel",
			"sheets"=>"sheet",
			"terabytes"=>"terabyte"
		}
	end

	def self.singularize_extent(extent_type)
		if self.singularized_extents.include?(extent_type)
			singularized_extent = self.singularized_extents[extent_type]
		else
			singularized_extent = extent_type
		end
		singularized_extent
	end

end