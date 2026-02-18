Refactor the weather service in examples/weather_service/ to support temperature units properly:
1. In models.zig, add a function 'pub fn convert(temp: f32, from: Unit, to: Unit) f32' to handle the math (C to F is (c * 9/5) + 32).
2. In provider.zig, update fetchTemperature to take a 'models.Unit' argument. It still returns Celsius from the hardcoded values, but MUST use models.convert to return the requested unit.
3. Update main.zig to use the new provider signature. It should fetch 'San Francisco' in Fahrenheit and print 'Weather in San Francisco: 59.9 degrees (fahrenheit)'.
4. Ensure the project builds and runs with 'zig run examples/weather_service/main.zig'.
5. Reply DONE when verified.