extern void OrbitBarBootstrap(void);

__attribute__((constructor))
static void orbitbar_dylib_init(void) {
    OrbitBarBootstrap();
}
