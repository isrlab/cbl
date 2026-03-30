System TrafficSignal

  Constants:
    RED_CYCLES    : integer [1..100] = 60
    GREEN_CYCLES  : integer [1..100] = 45
    YELLOW_CYCLES : integer [1..100] = 5

  Guarantees:
    light : {red, green, yellow}

  Initial mode: red

  Mode red:
    When true for RED_CYCLES consecutive cycles,
    shall set light to green,
         transition to green.
    Otherwise,
    shall set light to red,
         remain in red.

  Mode green:
    When true for GREEN_CYCLES consecutive cycles,
    shall set light to yellow,
         transition to yellow.
    Otherwise,
    shall set light to green,
         remain in green.

  Mode yellow:
    When true for YELLOW_CYCLES consecutive cycles,
    shall set light to red,
         transition to red.
    Otherwise,
    shall set light to yellow,
         remain in yellow.
