System TrafficLight

Assumes:
  pedestrian_request is a boolean signal
  timer_expired is a boolean signal

Constants:
  green_duration : integer = 30

Guarantees:
  light_color : {red, yellow, green} [default: hold]
  walk_signal : boolean

Initial Mode: Green

Mode Green:
  When timer_expired is true, shall set light_color to yellow, set walk_signal to false, transition to Yellow.
  Otherwise, shall set light_color to green, set walk_signal to false, remain in current.

Mode Yellow:
  When timer_expired is true, shall set light_color to red, set walk_signal to true, transition to Red.
  Otherwise, shall hold light_color, hold walk_signal, remain in current.

Mode Red:
  When timer_expired is true and pedestrian_request is true, shall set light_color to green, set walk_signal to false, transition to Green.
  Otherwise, shall hold light_color, set walk_signal to true, remain in current.

