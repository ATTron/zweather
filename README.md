# ZWEATHER

A basic weather CLI written in Zig.
Written to be instructional with the series on my blog [Implementing A Basic Weather CLI With Zig](https://atempleton.dev/posts/weather-cli-in-zig/)

![zweather](https://vhs.charm.sh/vhs-5HNF94uGlceSecLqQLyjli.gif)

## Usage

```bash
zweather -h
    -h, --help
            Display this help and exit

    -l, --location <str>
            City to lookup weather (ex. New York City)

    -u, --units <str>
            Which units to use (metric vs imperial)
```

### Example

```bash
zweather -l "new york city"
   Weather For City of New York, New York, United States : 😬
   > Currently it is clear outside
   > Tempurature: 44°F
   > Chance Of Rain: 0%
   > Humidity: 42%
   > UV Index: 0
```
