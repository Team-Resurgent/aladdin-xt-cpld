-- Xbox Original modchip code for XBlast-compatible firmware support
-- Copyright (C) 2019  Benjamin Fiset-Deschênes

-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Lesser General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- any later version.

-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU Lesser General Public License for more details.

-- You should have received a copy of the GNU Lesser General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.


-- Interface Xbox LPC to SST49LF080A flash device
-- Extra software control for bank switching
-- Design requires pull-ups on "pin_pad_bt" and "pin_pad_h0" at least
-- Internal pull-ups of LC4032V are sufficient in a normal Xbox environment

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;


-- ----------------------------------------
entity entity_lpcmod is
-- ----------------------------------------
    port (
        pin_xbox_n_lrst     : in    std_logic;                      -- Xbox-side Reset signal
        pin_xbox_lclk       : in    std_logic;                      -- Xbox-side CLK, goes to flash chip too
        pin_pad_bt          : in    std_logic;                      -- Xbox power button. Labeled "BT" on silkscreen, near unrouted LCD pad array.
        pin_pad_h0          : in    std_logic;                      -- Unused pad? Labeled "H0" on silkscreen, near D0 pad. Will be used for flash bank switch (2 * 512KB).
        pout_flash_lframe   : out   std_logic;                      -- Only goes to flash chip. Is generated by code logic.
        pinout4_xbox_lad    : inout std_logic_vector(3 downto 0);   -- Xbox-side LPC IO
        pinout4_flash_lad   : inout std_logic_vector(3 downto 0);   -- Flash-side LPC IO
        pinout_pad_d0       : inout std_logic ;                     -- D0 control on Xbox motherbord. Useful on all motherboards but 1.6(b) should really USE L1 instead!
        pinout_pad_x        : inout std_logic;                      -- Supports D0 to sink in more current.
        pinout_pad_l1       : inout std_logic                       -- LFRAME control on the Motherboard. Useful only on 1.6(b)
    );
end entity_lpcmod;

-- ----------------------------------------
architecture arch_lpcmod of entity_lpcmod is
-- ----------------------------------------
--**+ constants +***
    constant c_FALSE_STD: std_logic := '0';
    constant c_TRUE_STD: std_logic := '1';
    
    constant c_LAD_IDLE_PATTERN: std_Logic_vector := "1111";
    constant c_LAD_INPUT_PATTERN: std_Logic_vector := "ZZZZ";

    constant c_LAD_START_PATTERN: std_Logic_vector := "0000";
    constant c_CYC_MEM_PREFIX: std_Logic_vector := "01";
    constant c_CYC_IO_PREFIX: std_Logic_vector := "00";
    
    constant c_CYC_DIRECTION_READ: std_logic := '0';
    constant c_CYC_DIRECTION_WRITE: std_logic := '1';

    constant c_LAD_ADDR_PATTERN1: std_Logic_vector := "1111";

    constant c_LAD_ST49LF160C_ADDR_PATTERN1: std_Logic_vector := "1100"; -- Last fixed addr bit & 2 MSB Chip ID
    constant c_LAD_ST49LF160C_ADDR_PATTERN2: std_Logic_vector := "010"; -- chip ID bit(1) & Memory access signal bit & LSB Chip ID

    constant c_LAD_IOREG_PATTERN1: std_Logic_vector := "1111";
    constant c_LAD_IOREG_PATTERN2: std_Logic_vector := "0111";
    constant c_LAD_IOREG_PATTERN3: std_Logic_vector := "000";
    constant c_LAD_IOREG_PATTERN4_CTRL: std_Logic_vector := "1111";

    constant c_LAD_PATTERN_SYNC: std_Logic_vector := "0000";

    --constant c_OS_BANK_CONTROL_LOCK: boolean := true;

    constant c_DEV_ID_LOW_NIBBLE: std_logic_vector := "0001";  -- Matches SmartXX V1/Aladdin XBlast
    constant c_DEV_ID_HIGH_NIBBLE: std_logic_vector := "0001"; -- XBlast gen1
    
    constant c_FSM_ADDR_SEQ_NIBBLE0: integer := 0;
    constant c_FSM_ADDR_SEQ_NIBBLE1: integer := 1;
    constant c_FSM_ADDR_SEQ_NIBBLE2: integer := 2;
    constant c_FSM_ADDR_SEQ_NIBBLE3: integer := 3;
    constant c_FSM_ADDR_SEQ_NIBBLE4: integer := 4;
    constant c_FSM_ADDR_SEQ_NIBBLE5: integer := 5;
    constant c_FSM_ADDR_SEQ_NIBBLE6: integer := 6;
    constant c_FSM_ADDR_SEQ_NIBBLE7: integer := 7;
    constant c_FSM_ADDR_SEQ_MAX_COUNT: integer := c_FSM_ADDR_SEQ_NIBBLE7;
    constant c_FSM_DATA_SEQ_MAX_COUNT: integer := c_FSM_ADDR_SEQ_NIBBLE6;
    
    constant c_FSM_COUNT_RESET: integer := 0;
    constant c_FSM_COUNT_IO_START_OFFSET: integer := c_FSM_ADDR_SEQ_NIBBLE4;
    constant c_FSM_DATA_WRITE_LO_NIBBLE_OFFSET: integer := 0;
    constant c_FSM_DATA_WRITE_HI_NIBBLE_OFFSET: integer := 1;
    
    constant c_FSM_DATA_SEQ_TARA2_READ: integer := 1;
    constant c_FSM_DATA_SEQ_TARA2_WRITE: integer := 3;

    constant c_FSM_DATA_SEQ_DATA1_READ: integer := 3;
    constant c_FSM_DATA_SEQ_DATA2_READ: integer := 4;
    
    constant c_FSM_DATA_SEQ_SYNC_READ: integer := 2;
    constant c_FSM_DATA_SEQ_SYNC_WRITE: integer := 4;

--***+ types +***
    -- Regroup the necessary 17 cycle for a single byte of data transfer (both in R/W).
    type LPC_FSM is 
    (
        LPC_FSM_WAIT_START, -- 0000 read, occurs with LFRAME output asserted. Active while idle and on START frame (1/17 cycle)
        LPC_FSM_GET_CYC,    -- next nibble is CYCTYPE. Active 1/17 cycle.
        LPC_FSM_GET_ADDR,   -- 8 nibbles of address, most significant nibble first. Active 8/17 cycles for mem CYC ops or 4 for IO CYC ops
        LPC_FSM_DATA        -- TAR,SYNC and DATA transfer sequences. Active 7/17 cycles.
    );                      -- For a total of 17 cycles :)

--***+ signals +***
    signal s_lpc_fsm_state  : LPC_FSM;                      -- 2 bit state descriptor, unless you add entries to "LPC_FSM".
    signal s_fsm_counter    : integer range c_FSM_COUNT_RESET to c_FSM_ADDR_SEQ_MAX_COUNT;         -- Used for addresses resolution and LPC_FSM_DATA state counter.
    signal s_os_bnksw       : std_logic_vector(3 downto 0); -- OS desired bank switch state.
    signal s_lad_dir        : std_logic;                    -- 0 for Flash to Xbox(LPC read)
    signal s_bank3          : std_logic;                    -- Upper 1mb switch
    signal s_bank2          : std_logic;                    -- Intermediate signal for pin_pad_h0
    signal s_bank1          : std_logic;                    -- Intermediate signal for pin_pad_bt
    signal s_bank1_interm   : std_logic;                    -- Combined signal for pin_pad_bt and supplement logic
    signal s_os_disable     : std_logic := c_FALSE_STD;     -- Flag raised by OS to disable modchip and boot from onboard Bios.
    signal s_os_kill        : std_logic := c_FALSE_STD;     -- Flag raised by OS to kill modchip. Mainly for 1.6(b) compat
    signal s_is_init        : boolean := false;             -- Explicitely defined for a reason.
    signal s_os_bnkctrl     : boolean := false;             -- Explicitely defined for a reason.
    signal s_io_cyc         : boolean;                      -- When LPC transcation is IO read or write
    signal s_io_reg         : boolean;                      -- Single IO reg addr supporteed in this design
    
    
begin

--***+ direct signals +***
    s_bank3 <= '1' when s_os_bnkctrl = false else s_os_bnksw(2); -- Default to use upper 1mb
    s_bank2 <= pin_pad_h0 when s_os_bnkctrl = false else s_os_bnksw(1);
    s_bank1_interm <= pin_pad_bt when pin_pad_h0 = '1' and s_os_bnkctrl = false else pinout4_xbox_lad(2);
    s_bank1 <= s_bank1_interm when (s_os_bnkctrl = false or (s_os_bnksw(1) = '0' and s_os_bnksw(2) = '1')) else s_os_bnksw(0);

    -- Put pinout_pad_l1 in high impedance if s_os_kill is set. Xbox console can read the onboard BIOS. 
    -- If s_os_kill is not set, pinout_pad_l1 is forced to '1' only when LFRAME signal is asserted on Xbox motherboard.
    -- Eliminates the problem with most modchips not releasing LFRAME.
    pinout_pad_l1 <= 'Z' when s_os_kill = c_TRUE_STD or pinout4_xbox_lad = c_LAD_IDLE_PATTERN or s_lpc_fsm_state /= LPC_FSM_WAIT_START else '1';    

    -- Puts D0 on motherboard in High-Z when s_os_disable is set. Xbox console can read the onboard TSOP.
    pinout_pad_d0 <= 'Z' when s_os_disable = c_TRUE_STD else '0'; 

    -- When s_os_disable is not set, pinout_pad_d0 is forced to ground and Xbox reads from LPC bus instead
    pinout_pad_x <= 'Z' when s_os_disable = c_TRUE_STD else '0';

    --Recreate LFRAME for Flash chip. Async.
    pout_flash_lframe <= '0' when s_os_kill = c_FALSE_STD and pinout4_xbox_lad = c_LAD_START_PATTERN and s_lpc_fsm_state = LPC_FSM_WAIT_START else '1';

--***+ processes +***
    -- Process that cycle through all the steps of LPC transaction. 
    process_lpc_decode : process(pin_xbox_lclk)  -- 33MHz
    begin
        if rising_edge(pin_xbox_lclk) then
            if(pin_xbox_n_lrst = '0' or s_is_init /= true) then -- Still too early in boot sequence. We must wait for RST to go high.
                s_lpc_fsm_state <= LPC_FSM_WAIT_START;
                s_is_init <= true;
            else -- There we go!
                if s_fsm_counter < c_FSM_ADDR_SEQ_NIBBLE7 then
                    s_fsm_counter <= s_fsm_counter + 1;
                else
                    s_fsm_counter <= c_FSM_COUNT_RESET;
                end if;
                case s_lpc_fsm_state is
                    when LPC_FSM_WAIT_START =>  -- 0000 read, occurs with LFRAME output asserted
                        if pinout4_xbox_lad = c_LAD_START_PATTERN and s_os_disable = c_FALSE_STD then -- its a start
                            s_lpc_fsm_state <= LPC_FSM_GET_CYC;
                        end if;                         
                    when LPC_FSM_GET_CYC => -- next nibble is CYCTYPE, only interested in mem or IO r/w ops
                        if pinout4_xbox_lad(3 downto 2) = c_CYC_MEM_PREFIX then -- memory read or write
                            s_io_cyc <= false;
                            s_fsm_counter <= c_FSM_COUNT_RESET;    -- Reset counter for address decode.
                            s_lpc_fsm_state <= LPC_FSM_GET_ADDR;
                        elsif pinout4_xbox_lad(3 downto 2) = c_CYC_IO_PREFIX then -- io read or write
                            s_io_cyc <= true;        -- Flag to guide state machine below into IO operations
                            s_fsm_counter <= c_FSM_COUNT_IO_START_OFFSET;     -- Only 4 address nibbles are required in this case. IO write only requires 13 cycles.
                            s_lpc_fsm_state <= LPC_FSM_GET_ADDR;    -- LPC cycle goes on like normal.                    
                        else
                            s_lpc_fsm_state <= LPC_FSM_WAIT_START; -- sit out any unsupported cycle until the next start. This section could be expanded to allow other LPC message to go through
                            -- Maybe follow along any unsupported lpc transactions for more robustness?
                        end if;
                        s_lad_dir <= pinout4_xbox_lad(1);   --'0' is for read.
                    when LPC_FSM_GET_ADDR => -- 4/8 nibbles of address, most significant nibble first
                        case s_fsm_counter is
                            when c_FSM_ADDR_SEQ_NIBBLE0 | c_FSM_ADDR_SEQ_NIBBLE1 =>                           -- 2 first nibbles of a memory cycle must be "0xF".
                                if pinout4_xbox_lad /= c_LAD_ADDR_PATTERN1 then
                                    s_lpc_fsm_state <= LPC_FSM_WAIT_START; -- sit out any unsupported cycle until the next start.
                                    -- Again, this section could be expand in the event a program would want to access something else than BIOS flash.
                                    -- Maybe follow along any unsupported lpc transactions for more robustness?
                                end if; 
                            when c_FSM_ADDR_SEQ_NIBBLE4 =>
                                if s_io_cyc = true and pinout4_xbox_lad /= c_LAD_IOREG_PATTERN1 then      -- IO cycle: first nibble must be "0xF"  
                                    s_io_cyc <= false;                   -- Kick out of IO cycle state machine's branch
                                end if;
                            when c_FSM_ADDR_SEQ_NIBBLE5 =>
                                if s_io_cyc = true and pinout4_xbox_lad /= c_LAD_IOREG_PATTERN2 then      -- IO cycle: Second nibble must be "0x7"
                                    s_io_cyc <= false;                   -- Kick out of IO cycle state machine's branch
                                end if;
                            when c_FSM_ADDR_SEQ_NIBBLE6 =>
                                if s_io_cyc = true and pinout4_xbox_lad(3 downto 1) /= c_LAD_IOREG_PATTERN3 then     -- IO cycle: third nibble must be "0001". "0000" is also fine.   
                                                                                                                    -- LSB sets if cycle is for modchip control or other(LCD,etc.).
                                    s_io_cyc <= false;                   -- Kick out of IO cycle state machine's branch
                                end if;
                            when c_FSM_ADDR_SEQ_NIBBLE7 =>
                                s_fsm_counter <= c_FSM_COUNT_RESET;    -- Need to reset counter for LPC_FSM_DATA sequence.
                                if pinout4_xbox_lad = c_LAD_IOREG_PATTERN4_CTRL then
                                    s_io_reg <= true;
                                else
                                    s_io_reg <= false;
                                end if;
                                s_lpc_fsm_state <= LPC_FSM_DATA;  -- Next state once all 32 bits of addressing have been transferred (from the Xbox).
                            when others =>
                                null;
                        end case;
                    when LPC_FSM_DATA =>
                        if s_fsm_counter = c_FSM_DATA_SEQ_MAX_COUNT then
                            s_lpc_fsm_state <= LPC_FSM_WAIT_START;   -- Will always signals the end of a R/W cycle.
                        end if;
                    when others =>
                        null;   -- How did you get there?
                end case;                   
            end if; -- pin_xbox_n_lrst
        end if; -- clock
    end process process_lpc_decode;


    -- Process that control both LAD ports s_lad_dir
    -- Logic is determined by "s_lpc_fsm_state" and "s_fsm_counter" within a specific "s_lpc_fsm_state" value.
    process(s_lpc_fsm_state, s_lad_dir, s_fsm_counter, s_io_cyc, s_bank2, s_bank1, s_bank3)
    begin
        if s_lpc_fsm_state = LPC_FSM_DATA and s_lad_dir = c_CYC_DIRECTION_READ and s_fsm_counter >= c_FSM_DATA_SEQ_TARA2_READ and s_fsm_counter <= c_FSM_DATA_SEQ_MAX_COUNT  then  -- Sequences that reverse data flow. From LPC Flash to Xbox, during read operation.
            pinout4_flash_lad <= c_LAD_INPUT_PATTERN;     -- Flash chips is leading the show.
            if s_fsm_counter = c_FSM_DATA_SEQ_SYNC_READ then
                pinout4_xbox_lad <= c_LAD_PATTERN_SYNC; -- LPC_SYNC. Must be hard coded for IO read operations so why not use it for memory ops too.
            else
                if s_io_cyc = true and s_fsm_counter = c_FSM_DATA_SEQ_DATA1_READ then       -- Data low nibble
                    pinout4_xbox_lad <= c_DEV_ID_LOW_NIBBLE;
                elsif s_io_cyc = true and s_fsm_counter = c_FSM_DATA_SEQ_DATA2_READ then    -- Data high nibble
                    pinout4_xbox_lad <= c_DEV_ID_HIGH_NIBBLE;                                 
                else
                    pinout4_xbox_lad <= pinout4_flash_lad;   -- LPC_DATA1, LPC_DATA2 and LPC_TARB1 are now happening at the same time on both LAD ports
                end if;
            end if;
            -- The rest of the time, everybody is in high-Z with pull ups so the necessary 0xF nibbles are all there.
        elsif s_lpc_fsm_state = LPC_FSM_DATA and s_lad_dir = c_CYC_DIRECTION_WRITE and s_fsm_counter >= c_FSM_DATA_SEQ_TARA2_WRITE and s_fsm_counter <= c_FSM_DATA_SEQ_MAX_COUNT  then   -- Sequence that reverse data flow. From LPC Flash to Xbox, during write operation.
            pinout4_flash_lad <= c_LAD_INPUT_PATTERN;     -- Flash chips is leading the show.
            if s_fsm_counter = c_FSM_DATA_SEQ_SYNC_WRITE then
                pinout4_xbox_lad <= c_LAD_PATTERN_SYNC; -- LPC_SYNC. Must be hard coded for IO write operations so why not use it for memory ops too.
            else
                pinout4_xbox_lad <= pinout4_flash_lad;   -- LPC_SYNC and LPC_TARB1 are now happening at the same time on both LAD ports
            end if;
            -- The rest of the time, everybody is in high-Z with pull ups so the necessary 0xF nibbles are all there.                        
        else    -- If not one of the condition above, it means the data flow goes from the Xbox to the LPC flash. Happens on LPC_LFRAME start, LPC_CYC decode, 8 address nibbles, LPC_TARA1, LPC_TARB2 and of course when idle.
            pinout4_xbox_lad <= c_LAD_INPUT_PATTERN;     -- Also when s_lad_dir = '1' for LPC_DATA1 and LPC_DATA2.
            if s_lpc_fsm_state = LPC_FSM_GET_ADDR and s_fsm_counter = c_FSM_ADDR_SEQ_NIBBLE1 then
                pinout4_flash_lad <= c_LAD_ST49LF160C_ADDR_PATTERN1;
            elsif s_lpc_fsm_state = LPC_FSM_GET_ADDR and s_fsm_counter = c_FSM_ADDR_SEQ_NIBBLE2 then 
                
                if s_os_bnksw(3) = '1' then
                    pinout4_flash_lad <= pinout4_xbox_lad; 
                else
                    pinout4_flash_lad <= c_LAD_ST49LF160C_ADDR_PATTERN2 & s_bank3; -- c_LAD_ST49LF160C_ADDR_PATTERN2 i.e. 0X0X
                end if;

            elsif s_lpc_fsm_state = LPC_FSM_GET_ADDR and s_fsm_counter = c_FSM_ADDR_SEQ_NIBBLE3 then 

                if s_os_bnksw(3) = '1' then
                    pinout4_flash_lad <= pinout4_xbox_lad; 
                else
                    pinout4_flash_lad <= s_bank2 & s_bank1 & pinout4_xbox_lad(1 downto 0);   
                end if;

                -- Nibble's 2 MSB are controlled either by physical switches on pin_pad_h0 and pin_pad_bt at boot or by software when OS takes control. 
                -- Both pin_pad_h0 and pin_pad_bt have internal pull ups so leaving these ports floating will access the 
                -- highest 256KB of flash. Grounding either port will enable manual access to the lower 768KB portion of the 1MB flash.
                -- Useful to boot a user flash bank in the event of a OS corruption.
            else
                pinout4_flash_lad <= pinout4_xbox_lad;   -- Route DATA from Xbox LPC to the flash LPC port.
            end if;     
        end if;
    end process;


    -- IO operations decoding process.
    -- In charge of getting flash bank selection and chip enable state
    -- Essentially what makes it XBlast-compatible
    -- Extra R/W IO ops could be added in there (or in a separate process)
    process(s_io_cyc, s_lpc_fsm_state, s_lad_dir, pinout4_xbox_lad, s_io_reg, s_fsm_counter)
    begin
        if s_io_cyc = true and s_lpc_fsm_state = LPC_FSM_DATA and s_lad_dir = c_CYC_DIRECTION_WRITE and s_io_reg = true then       -- IO operation flag raised.
            -- Only IO write is implemented in this design.
            if s_fsm_counter = c_FSM_DATA_WRITE_LO_NIBBLE_OFFSET then -- IOWrite
                s_os_bnksw <= pinout4_xbox_lad; -- OS want to switch active flash bank
            elsif s_fsm_counter = c_FSM_DATA_WRITE_HI_NIBBLE_OFFSET then
                s_os_disable <= NOT pinout4_xbox_lad(0);
                s_os_kill <= pinout4_xbox_lad(1);
                s_os_bnkctrl <= true; -- Until power cycle
            end if; 
        end if;     
    end process;

end arch_lpcmod;