#
# Use Altera ModelSim:
#   module load modelsim/18.1
#
SOURCES         = zpu_alu.sv \
                  zpu_core.sv \
                  zpu_rom.sv \
                  testbench.sv \
                  memory.sv

all:            work

clean:
		rm -rf *.o *.vcd work

work:           $(SOURCES)
		vlib work
		vlog -sv $(SOURCES)

run:            work
		vsim -c -l run.log -do 'run 1us; quit' testbench +dump

view:
		gtkwave output.vcd databus.gtkw
