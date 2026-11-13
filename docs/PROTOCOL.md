# Sperax P2 Max protocol notes

Hardware scope: one **SPERAX_P2MAX / WLT6200** setup. Other products may use
different frames or meanings. These are independently observed protocol facts,
not a vendor specification.

| BLE role | UUID |
| --- | --- |
| Service | `0000fff0-0000-1000-8000-00805f9b34fb` |
| Notifications | `0000fff1-0000-1000-8000-00805f9b34fb` |
| Status query | `0000fff2-0000-1000-8000-00805f9b34fb` |

Status request, including checksum:

```text
F5 07 00 19 FA 59 FA
```

Frames begin with `F5`, carry an on-wire length and end with `FA`. The receiver
reassembles fragmented/coalesced BLE notifications, unescapes payload bytes and
validates CRC-16 initialized to `FFFF` with reflected polynomial `A327`.
The checksum is little-endian. Its input uses the normalized logical frame length;
the transmitted length includes escape bytes. `F0` followed by a low nibble
represents a logical `F0`–`FF` byte.

Offsets below refer to the validated, unescaped frame. A status frame has at
least 24 bytes, type `00 19` at offsets 2–3:

| Offset | Field | Interpretation |
| --- | --- | --- |
| 6 | Motion | `00`/`02` idle; `01` paused; `10` running; `11`–`13` countdown; `0F` stopping; `50` vibrating |
| 9–10 | Elapsed time | Big-endian seconds |
| 11–12 | Distance | Big-endian value × 10 metres |
| 15–16 | Steps | Big-endian cumulative counter |
| 17 | Speed | Value ÷ 10 km/h |

The automated tests retain only identity-free idle/framing vectors and synthetic
recordings. Full personal captures are not distributed.

No motor-control interface is included. Use the physical remote to start, stop
and change the belt. Do not treat a Bluetooth disconnect as proof the belt stopped.
