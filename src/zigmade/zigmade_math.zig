pub const math = @This();
pub const Vec2 = Vec(2, f32);
pub const Vec3 = Vec(3, f32);
pub const Vec4 = Vec(4, f32);
pub const Rectangle2 = Rectangle(Vec2);
pub const Rectangle3 = Rectangle(Vec3);

pub inline fn square(f: f32) f32 {
    const result = f * f;

    return result;
}

pub inline fn lerp(a: f32, t: f32, b: f32) f32 {
    const result = (1.0 - t) * a + t * b;

    return result;
}

pub inline fn clamp(min: f32, value: f32, max: f32) f32 {
    var result = value;

    if (result < min) {
        result = min;
    } else if (result > max) {
        result = max;
    }

    return result;
}

pub inline fn clamp01(value: f32) f32 {
    const result = clamp(0, value, 1);

    return result;
}

pub inline fn safeRatioN(numerator: f32, divisor: f32, n: f32) f32 {
    var result: f32 = n;

    if (divisor != 0) {
        result = numerator / divisor;
    }

    return result;
}

pub inline fn safeRatio0(numerator: f32, divisor: f32) f32 {
    const result = safeRatioN(numerator, divisor, 0);

    return result;
}

pub inline fn safeRatio1(numerator: f32, divisor: f32) f32 {
    const result = safeRatioN(numerator, divisor, 1);

    return result;
}

// Heavily inspired by Mach engine's math.vec
pub fn Vec(comptime n_value: usize, comptime Scalar: type) type {
    return extern struct {
        v: Vector,
        pub const n = n_value;
        pub const T = Scalar;
        pub const Vector = @Vector(n_value, Scalar);
        const VecN = @This();

        pub usingnamespace switch (VecN.n) {
            inline 2 => struct {
                pub inline fn init(xs: Scalar, ys: Scalar) VecN {
                    return .{ .v = .{ xs, ys } };
                }
                pub inline fn fromInt(xs: anytype, ys: anytype) VecN {
                    return .{ .v = .{ @floatFromInt(xs), @floatFromInt(ys) } };
                }
                pub inline fn x(v: *const VecN) Scalar {
                    return v.v[0];
                }
                pub inline fn y(v: *const VecN) Scalar {
                    return v.v[1];
                }
            },
            inline 3 => struct {
                pub inline fn init(xs: Scalar, ys: Scalar, zs: Scalar) VecN {
                    return .{ .v = .{ xs, ys, zs } };
                }
                pub inline fn fromInt(xs: anytype, ys: anytype, zs: anytype) VecN {
                    return .{ .v = .{ @floatFromInt(xs), @floatFromInt(ys), @floatFromInt(zs) } };
                }
                pub inline fn x(v: *const VecN) Scalar {
                    return v.v[0];
                }
                pub inline fn y(v: *const VecN) Scalar {
                    return v.v[1];
                }
                pub inline fn z(v: *const VecN) Scalar {
                    return v.v[2];
                }
                pub inline fn r(v: *const VecN) Scalar {
                    return v.v[0];
                }
                pub inline fn g(v: *const VecN) Scalar {
                    return v.v[1];
                }
                pub inline fn b(v: *const VecN) Scalar {
                    return v.v[2];
                }
                pub inline fn xy(v: *const VecN) Vec2 {
                    return Vec2.init(v.v[0], v.v[1]);
                }
                pub inline fn clamp01(v: *const VecN) VecN {
                    var result: VecN = undefined;

                    result.v[0] = math.clamp01(v.x());
                    result.v[1] = math.clamp01(v.y());
                    result.v[2] = math.clamp01(v.z());

                    return result;
                }
            },
            inline 4 => struct {
                pub inline fn init(xs: Scalar, ys: Scalar, zs: Scalar, ws: Scalar) VecN {
                    return .{ .v = .{ xs, ys, zs, ws } };
                }
                pub inline fn fromInt(xs: anytype, ys: anytype, zs: anytype, ws: anytype) VecN {
                    return .{ .v = .{ @floatFromInt(xs), @floatFromInt(ys), @floatFromInt(zs), @floatFromInt(ws) } };
                }
                pub inline fn x(v: *const VecN) Scalar {
                    return v.v[0];
                }
                pub inline fn y(v: *const VecN) Scalar {
                    return v.v[1];
                }
                pub inline fn z(v: *const VecN) Scalar {
                    return v.v[2];
                }
                pub inline fn w(v: *const VecN) Scalar {
                    return v.v[3];
                }
                pub inline fn r(v: *const VecN) Scalar {
                    return v.v[0];
                }
                pub inline fn g(v: *const VecN) Scalar {
                    return v.v[1];
                }
                pub inline fn b(v: *const VecN) Scalar {
                    return v.v[2];
                }
                pub inline fn a(v: *const VecN) Scalar {
                    return v.v[3];
                }
            },
            else => @compileError("Expected Vec2, Vec3, Vec4, found '" ++ @typeName(VecN) ++ "'"),
        };

        pub inline fn scale(a: *const VecN, s: Scalar) VecN {
            var result: VecN = undefined;

            result.v = a.v * VecN.splat(s).v;

            return result;
        }

        pub inline fn splat(scalar: Scalar) VecN {
            return .{ .v = @splat(scalar) };
        }

        pub inline fn negate(a: *const VecN) VecN {
            return switch (VecN.n) {
                inline 2 => .{ .v = Vec2(-1, -1).v * a.v },
                inline 3 => .{ .v = Vec3(-1, -1, -1).v * a.v },
                inline 4 => .{ .v = Vec4(-1, -1, -1, -1).v * a.v },
                else => @compileError("Expected Vec2, Vec3, Vec4, found '" ++ @typeName(VecN) ++ "'"),
            };
        }

        pub inline fn add(a: *const VecN, b: *const VecN) VecN {
            var result: VecN = undefined;

            result.v = a.v + b.v;

            return result;
        }

        pub inline fn sub(a: *const VecN, b: *const VecN) VecN {
            var result: VecN = undefined;

            result.v = a.v - b.v;

            return result;
        }

        pub inline fn hadamard(a: *const VecN, b: *const VecN) VecN {
            var result: VecN = undefined;

            result.v = a.v * b.v;

            return result;
        }

        pub inline fn inner(a: *const VecN, b: *const VecN) f32 {
            const result = @reduce(.Add, a.v * b.v);

            return result;
        }

        pub inline fn lengthSquared(a: *const VecN) f32 {
            const result = inner(a, a);

            return result;
        }

        pub inline fn length(vec: *const VecN) f32 {
            const result = @sqrt(lengthSquared(vec));

            return result;
        }
    };
}

pub fn Rectangle(comptime VecN: type) type {
    return extern struct {
        min: VecN,
        max: VecN,
        pub const T = VecN;
        const RectangleN = @This();

        pub usingnamespace switch (VecN.n) {
            inline 2 => struct {
                pub inline fn isInRectangle(rectangle: RectangleN, vec: VecN) bool {
                    const result = (vec.x() >= rectangle.min.x() and
                        vec.y() >= rectangle.min.y() and
                        vec.x() < rectangle.max.x() and
                        vec.y() < rectangle.max.y());

                    return result;
                }
            },
            inline 3 => struct {
                pub inline fn isInRectangle(rectangle: RectangleN, vec: VecN) bool {
                    const result = (vec.x() >= rectangle.min.x() and
                        vec.y() >= rectangle.min.y() and
                        vec.z() >= rectangle.min.z() and
                        vec.x() < rectangle.max.x() and
                        vec.y() < rectangle.max.y() and
                        vec.z() < rectangle.max.z());

                    return result;
                }
                pub inline fn rectanglesIntersect(a: RectangleN, b: RectangleN) bool {
                    const result = !(a.min.x() > b.max.x() or
                        a.max.x() < b.min.x() or
                        a.min.y() > b.max.y() or
                        a.max.y() < b.min.y() or
                        a.min.z() > b.max.z() or
                        a.max.z() < b.min.z());

                    return result;
                }
                pub inline fn getBarycentric(a: RectangleN, p: VecN) VecN {
                    var result: VecN = undefined;

                    result.v[0] = safeRatio0(p.x() - a.min.x(), a.max.x() - a.min.x());
                    result.v[1] = safeRatio0(p.y() - a.min.y(), a.max.y() - a.min.y());
                    result.v[2] = safeRatio0(p.z() - a.min.z(), a.max.z() - a.min.z());

                    return result;
                }
            },
            else => @compileError("Expected Vec2, Vec3, found '" ++ @typeName(VecN) ++ "'"),
        };

        pub inline fn init(min: VecN, max: VecN) VecN {
            return .{ .min = min, .max = max };
        }

        pub inline fn getMinCorner(rect: RectangleN) VecN {
            const result = rect.min;
            return result;
        }

        pub inline fn getMaxCorner(rect: RectangleN) VecN {
            const result = rect.max;
            return result;
        }

        pub inline fn getCenter(rect: RectangleN) VecN {
            const result = VecN.scale(
                VecN.add(rect.min, rect.max),
                0.5,
            );
            return result;
        }

        pub inline fn rectMinMax(min: VecN, max: VecN) RectangleN {
            var result: RectangleN = undefined;

            result.min = min;
            result.max = max;

            return result;
        }

        pub inline fn rectMinDim(min: VecN, dim: VecN) RectangleN {
            var result: RectangleN = undefined;

            result.min = min;
            result.max = VecN.add(min, dim);

            return result;
        }

        pub inline fn addRadius(
            rect: RectangleN,
            radius: VecN,
        ) RectangleN {
            var result: RectangleN = undefined;

            result.min = VecN.sub(&rect.min, &radius);
            result.max = VecN.add(&rect.max, &radius);

            return result;
        }

        pub inline fn centerDim(center: VecN, dim: VecN) RectangleN {
            const result = centerHalfDim(center, VecN.scale(&dim, 0.5));

            return result;
        }

        pub inline fn centerHalfDim(center: VecN, half_dim: VecN) RectangleN {
            var result: RectangleN = undefined;

            result.min = VecN.sub(&center, &half_dim);
            result.max = VecN.add(&center, &half_dim);

            return result;
        }
    };
}
