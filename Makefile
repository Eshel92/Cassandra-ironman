# Cassandra Multi-DC on Kind - Choose your approach:
#
#   make -f Makefile.cilium all        # Cilium ClusterMesh
#   make -f Makefile.submariner all    # Submariner
#
# Or use the shortcuts below:

.PHONY: cilium submariner clean-all help

cilium:
	$(MAKE) -f Makefile.cilium all

submariner:
	$(MAKE) -f Makefile.submariner all

clean-all:
	$(MAKE) -f Makefile.cilium clean || true
	$(MAKE) -f Makefile.submariner clean || true

help:
	@echo ""
	@echo "Cassandra Multi-DC on Kind"
	@echo ""
	@echo "Quick start:"
	@echo "  make cilium          Full Cilium ClusterMesh setup"
	@echo "  make submariner      Full Submariner setup"
	@echo "  make clean-all       Delete all clusters"
	@echo ""
	@echo "For individual targets:"
	@echo "  make -f Makefile.cilium help"
	@echo "  make -f Makefile.submariner help"
	@echo ""
