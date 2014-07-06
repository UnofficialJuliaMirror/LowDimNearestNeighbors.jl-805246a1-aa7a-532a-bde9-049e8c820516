# An implementation of the ideas described in A Minimalist's
# Implementation of an Approximate Nearest Neighbor Algorithm
# in Fixed Dimensions.
# Paper: http://cs.uwaterloo.ca/~tmchan/sss.ps
# Further reading: http://en.wikipedia.org/wiki/Z-order_curve

module SSS

export shuffless, shuffmore, shuffeq, preprocess!, nearest

# Return whether the index of the most significant bit
# of m is higher than that of n.
lessmsb(m, n) = m < n && m < (m $ n)

# Find the deciding dimension that determines which
# of p and q comes first in shuffle order. This is
# equivalent to finding the dimension with the most
# significant differing bit between p and q.
# Ties are broken in favor of lower-index dimensions;
# this is a consequence of the order in which the bits
# are conceptually interleaved.
function shuffdim(p, q)
	@assert length(p) == length(q)
	@assert length(p) > 0

	# For any integers x and y, the most significant
	# bit of x $ y is the most significant differing
	# bit between x and y.
	k, kxor = 1, p[1] $ q[1]
	for i in 2:length(p)
		ixor = p[i] $ q[i]
		if lessmsb(kxor, ixor)
			k, kxor = i, ixor
		end
	end
	k
end

# Define less-than, more-than, and equality.
shuffless(p, q) = (k = shuffdim(p, q); p[k] < q[k])
shuffmore(p, q) = (k = shuffdim(p, q); p[k] > q[k])
  shuffeq(p, q) = (k = shuffdim(p, q); p[k] == q[k])

# Sort an array by shuffle order to prepare it for nearest-neighbor queries.
function preprocess!(arr)
	for p in arr
		for i in length(p)
			p[i] < 0 && throw(ErrorException("All coordinates must be nonnegative."))
			!(typeof(p[i]) <: Integer) && throw(ErrorException("All coordinates must be integers."))
		end
	end

	sort!(arr, lt=shuffless)
end

# Saturation arithmetic for shifts: clamp instead of overflowing.
satplus{T}(a::T, b) = oftype(T, clamp(a + b, typemin(T), typemax(T)))

# Represent shifted points by their own type.
immutable Shifted{Q}
	data::Q
	shift::Int
end
Base.getindex(s::Shifted, args...) = satplus(s.data[args...], s.shift)
Base.length(s::Shifted) = length(s.data)

immutable Result{P, Q}
	point::P
	r_sq::Uint
	bbox_hi::Shifted{Q}
	bbox_lo::Shifted{Q}
	Result(point::P) = new(point, typemax(Uint))
	function Result(point::P, r_sq, q::Q)
		r = iceil(sqrt(r_sq))
		new(point, r_sq, Shifted{Q}(q, r), Shifted{Q}(q, -r))
	end
end

# Euclidean distance, though any p-norm will do.
function sqdist(p, q)
	@assert length(p) == length(q)
	@assert length(q) > 0

	local prev_d_sq::Uint
	d_sq::Uint = 0
	for i in 1:length(p)
		prev_d_sq = d_sq
		d_sq += uint((p[i] - q[i])^2) # Note: uint() rounds.
		d_sq < prev_d_sq && throw(ErrorException("Overflow: dist($p, $q)^2 does not fit into a Uint."))
	end
	d_sq
end

function sqdist_to_quadtree_box(q, p1, p2)
	@assert length(q) == length(p1) == length(p2)
	@assert length(q) > 0

	# Find the most significant differing bit of p1 and p2
	xor = p1[1] $ p2[1]
	for i in 2:length(p1)
		ixor = p1[i] $ p2[i]
		lessmsb(xor, ixor) && (xor = ixor)
	end

	# The size and power-of-two of the quadtree-aligned
	# bounding box that most snugly encloses p1 and p2
	power = xor == 0 ? 1 : 1 + exponent(float(xor))
	size = (1 << power)

	# Calculate the squared distance from q to the box.
	# The return value is a float for efficiency;
	# it will be multiplied by another float upon return.
	d_sq = 0.0
	for i in 1:length(q)
		# Compute the coordinates of the bounding box
		bbox_lo = (p1[i] >> power) << power
		bbox_hi = bbox_lo + size

		# Accumulate squared distance from the box
		if q[i] < bbox_lo
			d_sq += (q[i] - bbox_lo)^2
		elseif q[i] > bbox_hi
			d_sq += (q[i] - bbox_hi)^2
		end
	end
	d_sq
end

function nearest{P, Q}(arr::Array{P}, q::Q, lo::Uint, hi::Uint, R::Result{P, Q}, ε::Float64)
	# Return early if the range is empty.
	lo > hi && return R

	# Calculate the midpoint of the range, avoiding midpoint overflow.
	mid = (lo + hi) >>> 1

	# Compute the distance from the probe point to the query point,
	# and update the result if it's closer than our best match so far.
	r_sq = sqdist(arr[mid], q)
	r_sq < R.r_sq && (R = Result{P, Q}(arr[mid], r_sq, q))

	# Return early if the range is only one element wide or if the
	# bounding box containing the range is outside of our search radius.
	if lo == hi || sqdist_to_quadtree_box(q, arr[hi], arr[lo]) * (1.0 + ε)^2 >= R.r_sq
		return R
	end

	# Recurse. Unlike binary search, we occasionally recurse into
	# both halves of the array when we can't guarantee that the nearest
	# point lies inside a particular half.
	if shuffless(q, arr[mid])
		R = nearest(arr, q, lo, mid - 1, R, ε)
		shuffmore(R.bbox_hi, arr[mid]) && (R = nearest(arr, q, mid + 1, hi, R, ε))
	else
		R = nearest(arr, q, mid + 1, hi, R, ε)
		shuffless(R.bbox_lo, arr[mid]) && (R = nearest(arr, q, lo, mid - 1, R, ε))
	end

	R
end

function nearest{P, Q}(arr::Array{P}, q::Q, ε=0.0)
	@assert length(arr) > 0
	nearest(arr, q, uint(1), uint(length(arr)), Result{P, Q}(arr[1]), ε).point
end

end # module
