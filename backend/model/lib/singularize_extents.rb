module SingularizeExtents

	def self.singularized_extents
		{
			"linear_feet"=>"linear foot",
			"oversize folders"=>"oversize folder",
			"oversize volumes"=>"oversize volume",
			"volumes"=>"volume",
			"folders"=>"folder",
			"videotapes"=>"videotape",
			"audiotapes"=>"audiotape",
			"boxes"=>"box",
			"phonograph records"=>"phonograph record"
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