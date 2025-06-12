const std = @import("std");
const json = std.json;
const http = std.http;
const Chameleon = @import("chameleon");
const clap = @import("clap");

const TOMORROW_URL = "https://api.tomorrow.io/v4/weather/realtime?";

pub const App = struct {
    apiKey: []u8,
    allocator: std.mem.Allocator,
    units: []const u8,
    c: *Chameleon.RuntimeChameleon,
    location: []const u8,
};

pub const Root = struct {
    data: Data,
    location: Location,
};

pub const Data = struct {
    time: []u8,
    values: Values,
};

pub const Location = struct {
    lat: f64,
    lon: f64,
    name: []u8,
    type: []u8,
};

pub const Values = struct {
    cloudBase: ?f64,
    cloudCeiling: ?f64,
    cloudCover: ?f64,
    dewPoint: ?f64,
    freezingRainIntensity: ?f64 = null,
    humidity: ?f64,
    precipitationProbability: ?f64,
    pressureSeaLevel: ?f64,
    pressureSurfaceLevel: ?f64,
    rainIntensity: ?f64 = null,
    sleetIntensity: ?f64 = null,
    snowIntensity: ?f64 = null,
    temperature: ?f64,
    temperatureApparent: ?f64,
    uvHealthConcern: ?f64 = null,
    uvIndex: ?f64 = null,
    visibility: ?f64,
    weatherCode: ?u32,
    windDirection: ?f64,
    windGust: ?f64,
    windSpeed: ?f64,
};

pub const WeatherCodes = struct {
    // this is comptime by default since nothing about this structure relies on the runtime
    const codes = [_]struct { code: u32, description: []const u8 }{
        .{ .code = 0, .description = "unknown" },
        .{ .code = 1000, .description = "clear" },
        .{ .code = 1100, .description = "mostly clear" },
        .{ .code = 1101, .description = "partly cloudy" },
        .{ .code = 1102, .description = "mostly cloudy" },
        .{ .code = 1001, .description = "cloudy" },
        .{ .code = 2000, .description = "foggy" },
        .{ .code = 2100, .description = "lightly foggy" },
        .{ .code = 4000, .description = "drizzling" },
        .{ .code = 4001, .description = "raining" },
        .{ .code = 4200, .description = "light raining" },
        .{ .code = 4201, .description = "heavy raining" },
        .{ .code = 5000, .description = "snowing" },
        .{ .code = 5001, .description = "flurring" },
        .{ .code = 5100, .description = "light snowing" },
        .{ .code = 5101, .description = "heavy snowing" },
        .{ .code = 6000, .description = "freezing drizzle" },
        .{ .code = 6001, .description = "freezing raining" },
        .{ .code = 6200, .description = "light freezing raining" },
        .{ .code = 6201, .description = "heavy freezing raining" },
        .{ .code = 7000, .description = "ice pelleting" },
        .{ .code = 7101, .description = "heavy ice pelleting" },
        .{ .code = 7102, .description = "light ice pelleting" },
        .{ .code = 8000, .description = "thunderstorming" },
    };

    pub fn getDescription(code: u32) ?[]const u8 {
        // This will be optimized by the compiler into an efficient lookup
        inline for (codes) |entry| {
            if (entry.code == code) return entry.description;
        }
        return null;
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const apiKey = std.process.getEnvVarOwned(allocator, "TOMORROW_API_KEY") catch {
        std.log.info("API Key for tomorrow.io not found. Please set the environment variable \"TOMORROW_API_KEY\" to your tomorrow.io API key", .{});
        std.process.exit(1);
    };

    var c = Chameleon.initRuntime(.{ .allocator = allocator });
    defer c.deinit();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help              Display this help and exit
        \\-l, --location <str>    City to lookup weather (ex. New York City)
        \\-u, --units <str>       Which units to use (metric vs imperial)
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };

    defer res.deinit();

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    }

    const location = res.args.location orelse "New York City";
    const units = res.args.units orelse "imperial";

    const app = App{
        .apiKey = apiKey,
        .allocator = allocator,
        .units = units,
        .location = location,
        .c = &c,
    };

    try fetchWeatherData(app);
}

fn fetchWeatherData(app: App) !void {
    var client = http.Client{ .allocator = app.allocator };
    defer client.deinit();

    const uriString = "{s}location={s}&units={s}&apikey={s}";
    const formattedLocation = try cleanLocation(app.allocator, app.location);
    const url = try std.fmt.allocPrint(app.allocator, uriString, .{ TOMORROW_URL, formattedLocation, app.units, app.apiKey });
    defer app.allocator.free(url);

    const uri = try std.Uri.parse(url);

    const serverHeaderBuffer: []u8 = try app.allocator.alloc(u8, 1024 * 8);
    defer app.allocator.free(serverHeaderBuffer);

    // Make the connection to the server.
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = serverHeaderBuffer,
    });
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    const body = try req.reader().readAllAlloc(app.allocator, 1024 * 8);
    defer app.allocator.free(body);

    const parsed = try json.parseFromSlice(Root, app.allocator, body, .{});
    defer parsed.deinit();

    try handleDifferentWeather(app, parsed.value);
}

fn handleDifferentWeather(app: App, data: Root) !void {
    var defaultPreset: Chameleon.RuntimeChameleon = undefined;
    const normalizedTemperature = if (std.mem.eql(u8, "metric", app.units)) (data.data.values.temperature.? * 1.8) + 32 else data.data.values.temperature.?;
    switch (data.data.values.weatherCode.?) {
        1000, 1100 => {
            defaultPreset = try app.c.bold().yellow().createPreset();
            if (normalizedTemperature < 65.0) {
                defaultPreset = try app.c.bold().blueBright().createPreset();
            }
        },
        1101, 1102, 1001, 2000, 2100 => {
            defaultPreset = try app.c.bold().dim().createPreset();
        },
        4000, 4001, 4200, 4201 => {
            defaultPreset = try app.c.bold().blue().createPreset();
        },
        5000, 5001, 5100, 5101, 6000, 6001, 6200, 6201, 7000, 7101, 7102 => {
            defaultPreset = try app.c.bold().white().createPreset();
        },
        8000 => {
            defaultPreset = try app.c.bold().black().createPreset();
        },
        else => {
            defaultPreset = try app.c.bold().green().createPreset();
        },
    }
    try defaultPreset.printOut("   Weather For {s} : {s}\n", .{ data.location.name, getEmojiTemperature(normalizedTemperature) });

    const weatherCode = data.data.values.weatherCode.?;
    const currentWeather = WeatherCodes.getDescription(weatherCode).?;

    try defaultPreset.printOut("   > Currently it is {s} outside {s}\n", .{ currentWeather, getEmojiWeather(weatherCode) });
    try defaultPreset.printOut("   > Temperature: {d:.0}°", .{data.data.values.temperature.?});

    if (std.mem.eql(u8, "imperial", app.units)) {
        try defaultPreset.printOut("F\n", .{});
    } else {
        try defaultPreset.printOut("C\n", .{});
    }

    if (data.data.values.temperatureApparent.? != data.data.values.temperature.?) {
        try defaultPreset.printOut("   > Real Feel: {d:.0}°", .{data.data.values.temperatureApparent.?});
        if (std.mem.eql(u8, "imperial", app.units)) {
            try defaultPreset.printOut("F\n", .{});
        } else {
            try defaultPreset.printOut("C\n", .{});
        }
    }

    try defaultPreset.printOut("   > Wind Speed: {d:.0} m/s\n", .{data.data.values.windSpeed.?});
    try defaultPreset.printOut("   > Chance Of Rain: {d:.0}%\n", .{data.data.values.precipitationProbability.?});
    try defaultPreset.printOut("   > Humidity: {d:.0}%\n", .{data.data.values.humidity.?});
    if (data.data.values.uvIndex != null) {
        try defaultPreset.printOut("   > UV Index: {d:.0}\n", .{data.data.values.uvIndex.?});
    }
}

fn getEmojiTemperature(code: f64) []const u8 {
    switch (@as(i32, @intFromFloat(code))) {
        -150...32 => {
            return "🥶";
        },
        33...60 => {
            return "😬";
        },
        61...85 => {
            return "😁";
        },
        else => {
            return "🥵";
        },
    }
}

fn getEmojiWeather(code: u32) []const u8 {
    switch (code) {
        1000 => {
            return "☀️";
        },
        1100 => {
            return "🌤️";
        },
        1101 => {
            return "⛅";
        },
        1102 => {
            return "🌥️";
        },
        1001 => {
            return "☁️";
        },
        2000, 2100 => {
            return "🌁";
        },
        4000, 4001, 4200, 4201 => {
            return "🌧️";
        },
        5000, 5001, 5100, 5101 => {
            return "🌨️";
        },
        6000, 6001, 6200, 6201, 7000, 7101, 7102 => {
            return "🧊🌧️";
        },
        8000 => {
            return "⛈️";
        },
        else => {
            return "🥵";
        },
    }
}

fn cleanLocation(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const size = std.mem.replacementSize(u8, input, " ", "_");
    const output = try allocator.alloc(u8, size);
    _ = std.mem.replace(u8, input, " ", "_", output);

    return output;
}
