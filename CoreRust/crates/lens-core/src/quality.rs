//! Character and word error rates for offline OCR/transcript gates.

/// Levenshtein distance over Unicode scalars.
pub fn edit_distance(left: &str, right: &str) -> usize {
    let a: Vec<char> = left.chars().collect();
    let b: Vec<char> = right.chars().collect();
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut next = vec![0; b.len() + 1];
    for (i, ca) in a.iter().enumerate() {
        next[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let cost = usize::from(ca != cb);
            next[j + 1] = (prev[j + 1] + 1).min(next[j] + 1).min(prev[j] + cost);
        }
        std::mem::swap(&mut prev, &mut next);
    }
    prev[b.len()]
}

pub fn normalize_text(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_whitespace() {
                ' '
            } else {
                ch.to_lowercase().next().unwrap_or(ch)
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Character error rate. Empty reference yields 0 if hypothesis is also empty, else 1.
pub fn character_error_rate(reference: &str, hypothesis: &str) -> f64 {
    let reference = normalize_text(reference);
    let hypothesis = normalize_text(hypothesis);
    if reference.is_empty() {
        return if hypothesis.is_empty() { 0.0 } else { 1.0 };
    }
    let distance = edit_distance(&reference, &hypothesis) as f64;
    distance / reference.chars().count() as f64
}

/// Word error rate on whitespace-separated tokens.
pub fn word_error_rate(reference: &str, hypothesis: &str) -> f64 {
    let reference = normalize_text(reference);
    let hypothesis = normalize_text(hypothesis);
    let ref_words: Vec<&str> = reference.split(' ').filter(|w| !w.is_empty()).collect();
    let hyp_words: Vec<&str> = hypothesis.split(' ').filter(|w| !w.is_empty()).collect();
    if ref_words.is_empty() {
        return if hyp_words.is_empty() { 0.0 } else { 1.0 };
    }
    let mut prev: Vec<usize> = (0..=hyp_words.len()).collect();
    let mut next = vec![0; hyp_words.len() + 1];
    for (i, rw) in ref_words.iter().enumerate() {
        next[0] = i + 1;
        for (j, hw) in hyp_words.iter().enumerate() {
            let cost = usize::from(rw != hw);
            next[j + 1] = (prev[j + 1] + 1).min(next[j] + 1).min(prev[j] + cost);
        }
        std::mem::swap(&mut prev, &mut next);
    }
    prev[hyp_words.len()] as f64 / ref_words.len() as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identical_text_is_zero_error() {
        assert_eq!(character_error_rate("你好世界", "你好世界"), 0.0);
        assert_eq!(word_error_rate("hello world", "Hello  WORLD"), 0.0);
    }

    #[test]
    fn chinese_substitution_is_one_over_length() {
        let cer = character_error_rate("你好世界", "你好世间");
        assert!((cer - 0.25).abs() < 1e-9);
    }

    #[test]
    fn english_word_substitution_is_one_over_count() {
        let wer = word_error_rate("the cat sat", "the dog sat");
        assert!((wer - 1.0 / 3.0).abs() < 1e-9);
    }

    #[test]
    fn g5_thresholds_are_the_product_gates() {
        assert!(character_error_rate("固定中文样本", "固定中文样本") <= 0.05);
        assert!(word_error_rate("fixed english sample", "fixed english sample") <= 0.15);
    }
}
