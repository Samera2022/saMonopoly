use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Card {
    pub id: String,
    pub name_key: String,
    pub effect_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CardDeck {
    pub id: String,
    pub cards: Vec<Card>,
}

impl CardDeck {
    /// Shuffles the deck using Fisher-Yates algorithm.
    /// Takes a closure returning `u64` as the random source.
    pub fn shuffle(&mut self, rng: &mut impl FnMut() -> u64) {
        let len = self.cards.len();
        for i in (1..len).rev() {
            let j = (rng() as usize) % (i + 1);
            self.cards.swap(i, j);
        }
    }

    /// Draws the top card from the deck (pop from the end).
    pub fn draw(&mut self) -> Option<Card> {
        self.cards.pop()
    }
}
