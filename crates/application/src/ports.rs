pub trait RngService {
    fn next_u64(&mut self) -> u64;
}

pub trait TimeProvider {
    fn now_millis(&self) -> u64;
}

pub trait MapValidator<M> {
    fn validate(&self, map: &M) -> Result<(), Vec<String>>;
}
