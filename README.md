# 📦 MESI Cache Coherence Protocol (Verilog RTL)

## 📖 Overview
This project implements the **MESI (Modified, Exclusive, Shared, Invalid) Cache Coherence Protocol** using **Verilog HDL** at the RTL level.  

The design models a multi-cache system where coherence is maintained through state transitions and bus-based communication, ensuring consistency of data across caches.

---

## 🎯 Objectives
- Implement the **MESI protocol** in Verilog
- Design cache controllers with proper state transitions
- Maintain **data consistency** in a shared memory system
- Verify functionality using **testbenches and simulation**
- Analyze behavior under different read/write scenarios

---

## 🧠 MESI Protocol Description

The MESI protocol uses four states:

| State | Description |
|------|-------------|
| **M (Modified)** | Data is modified and exists only in this cache |
| **E (Exclusive)** | Data is clean and present only in this cache |
| **S (Shared)** | Data is clean and may exist in multiple caches |
| **I (Invalid)** | Data is not valid |

---

## 🔄 State Transitions

### Read Operation
- **Read Hit** → No state change  
- **Read Miss**:
  - If no other cache has data → **Exclusive (E)**
  - If shared by others → **Shared (S)**

### Write Operation
- **Write Hit**:
  - S → M (invalidate others)
  - E → M
- **Write Miss**:
  - Fetch data → Move to **Modified (M)**

### Snooping (Bus Events)
- Read request from another cache:
  - M → S (write-back required)
  - E → S
- Write request from another cache:
  - M/S/E → I

---


---

## ⚙️ Design Components
- Cache Controller (MESI FSM)
- Main Memory Model
- Bus Interface Logic
- Multi-cache interaction logic
- Testbench for validation

---

## 🧪 Simulation & Verification
The design is verified using:
- Directed testcases:
  - Read hit/miss
  - Write hit/miss
  - Cache-to-cache interaction
- Waveform analysis to observe:
  - State transitions
  - Bus transactions
  - Data consistency

## Results
Correct MESI state transitions observed
Proper invalidation and sharing behavior
No stale data or coherence violations detected

