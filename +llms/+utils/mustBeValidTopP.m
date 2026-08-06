function mustBeValidTopP(value)
%mustBeValidTopP   Validate the top probability mass value.
%
%   mustBeValidTopP(VALUE) validates whether the input VALUE is a valid top
%   probability mass value. The VALUE must be a real, non-negative, non-sparse
%   scalar numeric value less than or equal to 1.

%   Copyright 2023 The MathWorks, Inc.

validateattributes(value, {'numeric'}, {'real', 'scalar', 'nonnegative', 'nonsparse', '<=', 1})
end