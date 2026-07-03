use sa_monopoly_application::ports::RngService;

pub trait SeededRng {
    fn seed(&mut self, seed: u64);
    fn next_u64(&mut self) -> u64;
}

#[derive(Debug, Clone)]
pub struct XorShift64 {
    state: u64,
}

impl XorShift64 {
    pub fn new(seed: u64) -> Self {
        Self { state: seed.max(1) }
    }
}

impl SeededRng for XorShift64 {
    fn seed(&mut self, seed: u64) {
        self.state = seed.max(1);
    }

    fn next_u64(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        x
    }
}

impl RngService for XorShift64 {
    fn next_u64(&mut self) -> u64 {
        SeededRng::next_u64(self)
    }
}
