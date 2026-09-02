pub trait DurableProduct {
    fn init(&mut self, seed: u64);
    fn handle(&mut self, event: &[u8]) -> Vec<u8>;
    fn snapshot(&self) -> Vec<u8>;
    fn restore(&mut self, state: &[u8]);
    fn state_hash(&self) -> [u8; 32];
}
