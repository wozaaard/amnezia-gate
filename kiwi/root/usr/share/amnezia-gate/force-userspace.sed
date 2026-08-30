/^[[:space:]]*local ret$/a\
	if [[ ${WG_QUICK_FORCE_USERSPACE:-0} == 1 ]]; then\
		cmd "${WG_QUICK_USERSPACE_IMPLEMENTATION:-amneziawg-go}" "$INTERFACE"\
		return\
	fi
