# Schematics (ASCII)

## Transmitter — Full Schematic

```
                                                                     
                        +5V (from drone BEC)                         
                         │                                            
                         ├── 100nF+10µF decoupling ── GND             
                         │                                            
                         ▼                                            
            ┌────────────────────────────┐                            
            │          ESP32             │                            
            │          WROOM-32          │                            
            │                            │                            
   Pixhawk  │                            │                            
   TELEM    │                            │                            
    TX ─────┤ GPIO16 (U2_RX)             │                            
    RX ─────┤ GPIO17 (U2_TX)             │                            
    GND ────┤ GND                        │                            
            │                            │         C1 100nF   R2 4.7k 
            │                  GPIO25 ───┼────┤├──────┬──────────── MIC
            │                  (DAC1)    │              │            (to radio
            │                            │             R1 10kΩ       mic jack)
            │                            │              │             
            │                            │             GND            
            │                            │                            
            │                            │         R_B 1kΩ            
            │                   GPIO4 ───┼───┳───┤                    
            │                   (PTT)    │   │   │   Q1 2N2222        
            │                            │   │   ┣── Base             
            │                            │   │   │                    
            └────────────────────────────┘   │   ┃ Collector ── PTT pin
                                             │   │           (to radio)
                                             │   ┃ Emitter                    
                                             │   │                    
                                             ▼   ▼                    
                                            GND GND                   
```

## Receiver — Full Schematic

```
                        +5V (from USB or BEC)                        
                         │                                            
                         ├── 100nF+10µF decoupling ── GND             
                         │                                            
                         ▼                                            
            ┌────────────────────────────┐                            
            │          ESP32             │                            
            │          WROOM-32          │                            
            │                            │                            
   GCS PC   │                            │                            
   (USB ser)│                            │                            
    CDC ◄───┤ USB (via on-board CP210x)  │                            
            │                            │                            
   Mission  │                            │                            
   Planner  │                            │                            
   RX ─────┤ GPIO17 (U2_TX)              │                            
   GND ────┤ GND                         │                            
            │                            │         C2 100nF   R3 10k  
            │                            │                            
   Radio    │                  GPIO34 ◄──┼────┤├──────┬──────────── SPK+
   Speaker  │                  (ADC1_6)  │              │          (from radio
   Out   ───┤                            │             R4 4.7kΩ     speaker
            │                            │              │          jack)     
            │                            │             GND            
            │                            │                            
            │                   GPIO2 ───┼──── LED  ──── GND          
            │                   (STATUS) │       (220Ω series R)      
            │                            │                            
            └────────────────────────────┘                            
```

## Bill of Materials (per unit)

| Qty | Part            | Value    | Package    | Notes |
|-----|-----------------|----------|------------|-------|
| 1   | ESP32 WROOM-32 devkit | — | 38-pin dev board | DevKitC v4 recommended |
| 2   | Ceramic cap     | 100 nF   | 0805       | Decoupling + AC coupling |
| 1   | Electrolytic    | 10 µF    | radial     | Bulk decoupling |
| 1   | Resistor        | 10 kΩ    | 0805       | R1 — mic divider bottom |
| 1   | Resistor        | 4.7 kΩ   | 0805       | R2 — mic series / R4 bias |
| 1   | Resistor        | 1 kΩ     | 0805       | R_B — PTT base |
| 1   | Transistor      | 2N2222/BC547 | TO-92/SOT-23 | Q1 PTT driver |
| 1   | LED             | any colour | 3mm or 0805 | Status |
| 1   | Resistor        | 220 Ω    | 0805       | LED series |
| 1   | Ferrite bead    | 600 Ω @ 100 MHz | 0805 | On audio line (optional) |

---

## Recommended Enclosure Layout

- **Transmitter (drone):** compact aluminium or carbon-fibre box, mounted away from ESCs.  Audio and PTT wires run in shielded cable to the radio.  Radio itself should be placed away from the flight controller (>15 cm) to reduce RX desense from the flight controller's microcontroller clock harmonics.

- **Receiver (ground):** 3D-printed case with BNC or SMA antenna pass-through if the receiver shares the enclosure with an antenna.  USB cable out for Mission Planner.
