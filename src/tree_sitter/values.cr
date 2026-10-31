# src/tree_sitter/values.cr

module TreeSitter
  # A position in the text: a zero-based row and a byte column within it.
  record Point, row : Int32, column : Int32 do
    # The C form of this point.
    def to_lib : LibTreeSitter::Point
      LibTreeSitter::Point.new(row: @row.to_u32, column: @column.to_u32)
    end

    # The point a C point describes.
    def self.of(point : LibTreeSitter::Point) : Point
      new(point.row.to_i, point.column.to_i)
    end
  end

  # One text replacement, given to `Tree#edit` before reparsing: where it starts, where the replaced text ended and
  # where the new text ends, as bytes and as points.
  record Edit, start_byte : Int32, old_end_byte : Int32, new_end_byte : Int32,
    start_point : Point, old_end_point : Point, new_end_point : Point do
    # The C form of this edit.
    def to_lib : LibTreeSitter::InputEdit
      LibTreeSitter::InputEdit.new(start_byte: @start_byte.to_u32, old_end_byte: @old_end_byte.to_u32,
        new_end_byte: @new_end_byte.to_u32, start_point: @start_point.to_lib, old_end_point: @old_end_point.to_lib,
        new_end_point: @new_end_point.to_lib)
    end
  end
end
