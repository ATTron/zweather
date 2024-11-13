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
    weatherCodes: std.AutoArrayHashMap(u32, []const u8),
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
    freezingRainIntensity: ?f64,
    humidity: ?f64,
    precipitationProbability: ?f64,
    pressureSurfaceLevel: ?f64,
    rainIntensity: ?f64,
    sleetIntensity: ?f64,
    snowIntensity: ?f64,
    temperature: ?f64,
    temperatureApparent: ?f64,
    uvHealthConcern: ?f64,
    uvIndex: ?f64,
    visibility: ?f64,
    weatherCode: ?u32,
    windDirection: ?f64,
    windGust: ?f64,
    windSpeed: ?f64,
};

pub fn main() !void {
    // var location: ?[]u8 = undefined;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const apiKey = std.process.getEnvVarOwned(allocator, "TOMORROW_API_KEY") catch {
        std.log.info("API Key for tomorrow.io not found. Please set the environment variable \"TOMORROW_API_KEY\" to your tomorrow.io API key", .{});
        std.process.exit(1);
    };

    var codes = try initWeatherCodes(allocator);
    defer codes.deinit();

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
        .weatherCodes = codes,
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
    switch (data.data.values.weatherCode.?) {
        1000, 1100 => {
            defaultPreset = try app.c.bold().yellow().createPreset();
            if (data.data.values.temperature.? < 65) {
                defaultPreset = try app.c.bold().blueBright().createPreset();
            }
        },
        1101, 1102, 1001, 2000, 2100 => {
            defaultPreset = try app.c.bold().grey().createPreset();
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
    try defaultPreset.printOut("   Weather For {s} : {s}\n", .{ data.location.name, getEmoji(data.data.values.temperature.?) });

    const weatherCode = data.data.values.weatherCode.?;
    const currentWeather = app.weatherCodes.get(weatherCode).?;

    try defaultPreset.printOut("   > Currently it is {s} outside\n", .{currentWeather});
    try defaultPreset.printOut("   > Tempurature: {d:.0}°", .{data.data.values.temperature.?});

    if (std.mem.eql(u8, "imperial", app.units)) {
        try defaultPreset.printOut("F\n", .{});
    } else {
        try defaultPreset.printOut("C\n", .{});
    }

    if (data.data.values.temperatureApparent.? != data.data.values.temperature.?) {
        try defaultPreset.printOut("   > Real Feel: {d:.0}°\n", .{data.data.values.temperatureApparent.?});
        if (std.mem.eql(u8, "imperial", app.units)) {
            try defaultPreset.printOut("F\n", .{});
        } else {
            try defaultPreset.printOut("C\n", .{});
        }
    }

    try defaultPreset.printOut("   > Wind Speed: {d:.0}\n", .{data.data.values.windSpeed.?});
    try defaultPreset.printOut("   > Chance Of Rain: {d:.0}%\n", .{data.data.values.precipitationProbability.?});
    try defaultPreset.printOut("   > Humidity: {d:.0}%\n", .{data.data.values.humidity.?});
    try defaultPreset.printOut("   > UV Index: {d:.0}\n", .{data.data.values.uvIndex.?});
}

fn getEmoji(code: f64) []const u8 {
    switch (@as(i32, @intFromFloat(code))) {
        -100.0...32.0 => {
            return "🥶";
        },
        33.0...60.0 => {
            return "😬";
        },
        61.0...85.0 => {
            return "😁";
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

fn initWeatherCodes(allocator: std.mem.Allocator) !std.AutoArrayHashMap(u32, []const u8) {
    var codes = std.AutoArrayHashMap(u32, []const u8).init(allocator);
    try codes.put(0, "unknown");
    try codes.put(1000, "clear");
    try codes.put(1100, "mostly clear");
    try codes.put(1101, "Partly cloudy");
    try codes.put(1102, "mostly cloudy");
    try codes.put(1001, "cloudy");
    try codes.put(2000, "fog");
    try codes.put(2100, "light fog");
    try codes.put(4000, "dizzle");
    try codes.put(4001, "rain");
    try codes.put(4200, "light rain");
    try codes.put(4201, "heavy rain");
    try codes.put(5000, "snow");
    try codes.put(5001, "flurries");
    try codes.put(6000, "freezing drizzle");
    try codes.put(6001, "freezing rain");
    try codes.put(6200, "light freezing rain");
    try codes.put(6201, "heavy freezing rain");
    try codes.put(7000, "ice pellets");
    try codes.put(7101, "heavy ice pellets");
    try codes.put(7102, "light ice pellets");
    try codes.put(8000, "thunderstorm");

    return codes;
}
